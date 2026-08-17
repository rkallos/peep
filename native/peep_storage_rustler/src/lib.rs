use hashbrown::hash_map::{HashMap, RawEntryMut};
use rustler::sys::{enif_monotonic_time, enif_system_info, ErlNifSysInfo, ErlNifTimeUnit};
use rustler::types::map::MapIterator;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, NifMap, Resource, ResourceArc, Term, TermType};
use std::cell::{Cell, UnsafeCell};
use std::hash::{BuildHasherDefault, Hash, Hasher};
use std::mem::size_of;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock, RwLock};

mod metric_atoms {
    rustler::atoms! {
        counter = "Elixir.Telemetry.Metrics.Counter",
        sum = "Elixir.Telemetry.Metrics.Sum",
        last_value = "Elixir.Telemetry.Metrics.LastValue",
        distribution = "Elixir.Telemetry.Metrics.Distribution",
        peep_bucket_boundaries,
    }
}

/// Keys used in a Distribution's output map alongside its plain-integer
/// bucket indices - kept separate from `metric_atoms` since these aren't
/// struct names.
mod output_atoms {
    rustler::atoms! {
        infinity,
        sum,
    }
}

/// The BEAM's actual configured scheduler count (`:erlang.system_info(:schedulers)`),
/// queried directly via `enif_system_info` rather than round-tripping
/// through Elixir. Deliberately *not* `:schedulers_online`: that can change
/// at runtime via `:erlang.system_flag(:schedulers_online, _)`, but shard
/// arrays are sized once at registration time, and `resolve/1`'s
/// `scheduler_id` values range over `1..schedulers` regardless of how many
/// happen to be online at any given moment - sizing against the smaller,
/// mutable count would let a `scheduler_id` exceed the shard array.
fn scheduler_count() -> usize {
    let mut info: ErlNifSysInfo = unsafe { std::mem::zeroed() };
    unsafe {
        enif_system_info(&mut info, size_of::<ErlNifSysInfo>());
    }
    info.scheduler_threads as usize
}

/// A monotonic timestamp (nanoseconds), queried directly via the NIF API.
/// Used to break ties between shards when merging `LastValue` entries in
/// `get_all_metrics` - only ever compared against other values from this
/// same function within this same node, so there's no need to match
/// Elixir's own `System.monotonic_time/0` unit, or pay for a BIF round trip
/// to get it.
fn monotonic_time_ns() -> i64 {
    unsafe { enif_monotonic_time(ErlNifTimeUnit::ERL_NIF_NSEC) }
}

struct Storage {
    // Populated once, by `register_metrics`, some time after `new` returns
    // the resource. `OnceLock` gives lock-free reads on the (extremely hot)
    // `insert_metric` path without needing a lock that's only ever
    // contended during that one-time setup.
    registered: OnceLock<RegisteredMetrics>,

    // MEASUREMENT SCAFFOLDING, not part of the real storage - see
    // `UnsyncSlots`. Prices what the per-shard `RwLock` and the atomic RMW
    // cost by offering the same lookup with neither.
    unsync: OnceLock<UnsyncSlots>,
}

/// Deliberately-unsound `Sync` wrapper, so an `UnsafeCell` can live inside a
/// `Resource`. Exists only to measure the cost of the synchronization the
/// real hot path pays: nothing here is safe to drive from more than one
/// thread, and the benchmarks that use it write from one thread at a time.
struct UnsyncCell<T>(UnsafeCell<T>);

// SAFETY: not actually safe. See above - measurement scaffolding only.
unsafe impl<T> Sync for UnsyncCell<T> {}

// Same caveat: asserted purely so this scaffolding can live in a `Resource`.
impl<T> std::panic::RefUnwindSafe for UnsyncCell<T> {}

impl<T> UnsyncCell<T> {
    #[inline]
    fn get(&self) -> *mut T {
        self.0.get()
    }

    fn shards(n_shards: usize) -> Box<[CachePadded<Self>]>
    where
        T: Default,
    {
        (0..n_shards)
            .map(|_| CachePadded(UnsyncCell(UnsafeCell::new(T::default()))))
            .collect()
    }
}

type PlainCounterMap = HashMap<TagsKey, i64, TermHashBuilder>;
type UnlockedAtomicMap = HashMap<TagsKey, AtomicI64, TermHashBuilder>;

/// Two parallel shadow copies of the Counter storage, one per metric id, each
/// sharded per scheduler exactly like the real `Counters`:
///
///   * `unlocked_atomic` - no `RwLock`, values still `AtomicI64`
///   * `unlocked_plain`  - no `RwLock`, values plain `i64`
///
/// Differencing the three insert paths (real, `unlocked_atomic`,
/// `unlocked_plain`) separates the lock's cost from the atomic's.
struct UnsyncSlots {
    unlocked_atomic: Vec<Box<[CachePadded<UnsyncCell<UnlockedAtomicMap>>]>>,
    unlocked_plain: Vec<Box<[CachePadded<UnsyncCell<PlainCounterMap>>]>>,
    // Locks guarding nothing, taken around the *same* unsynchronized insert
    // `unlocked_atomic` does. The only difference between
    // `insert_counters_unlocked_atomic` and `insert_counters_dummy_locked` is
    // the read guard, so differencing them prices `RwLock::read` and its guard
    // drop and nothing else.
    dummy_locks: Vec<Box<[CachePadded<RwLock<()>>]>>,
    // Same, but `parking_lot`'s RwLock rather than std's, to test whether the
    // cost is inherent to reader-writer locking or specific to std's macOS
    // implementation.
    dummy_pl_locks: Vec<Box<[CachePadded<PlLock>]>>,
}

/// `parking_lot::RwLock` isn't `RefUnwindSafe`, which a `Resource` field has to
/// be. Asserted here purely so this scaffolding can be measured.
struct PlLock(parking_lot::RwLock<()>);

impl std::panic::RefUnwindSafe for PlLock {}

impl PlLock {
    #[inline]
    fn read(&self) -> parking_lot::RwLockReadGuard<'_, ()> {
        self.0.read()
    }
}

impl UnsyncSlots {
    fn new(n_metrics: usize, n_shards: usize) -> Self {
        UnsyncSlots {
            unlocked_atomic: (0..n_metrics).map(|_| UnsyncCell::shards(n_shards)).collect(),
            unlocked_plain: (0..n_metrics).map(|_| UnsyncCell::shards(n_shards)).collect(),
            dummy_locks: (0..n_metrics)
                .map(|_| {
                    (0..n_shards)
                        .map(|_| CachePadded(RwLock::new(())))
                        .collect()
                })
                .collect(),
            dummy_pl_locks: (0..n_metrics)
                .map(|_| {
                    (0..n_shards)
                        .map(|_| CachePadded(PlLock(parking_lot::RwLock::new(()))))
                        .collect()
                })
                .collect(),
        }
    }
}

// A shard index owned by the OS thread itself, rather than handed in from
// Elixir. Assigned on first use from `NEXT_THREAD_SHARD`. This is the
// alternative to `resolve/1`'s `:erlang.system_info(:scheduler_id)`: a
// scheduler id read in Elixir can go stale (the process may be preempted and
// migrated between `resolve/1` and the insert), whereas a thread-local is by
// construction the thread actually executing the NIF.
thread_local! {
    static THREAD_SHARD: Cell<usize> = const { Cell::new(usize::MAX) };
}

static NEXT_THREAD_SHARD: AtomicU64 = AtomicU64::new(0);

#[inline]
fn thread_shard(n_shards: usize) -> usize {
    THREAD_SHARD.with(|cell| match cell.get() {
        usize::MAX => {
            let assigned = NEXT_THREAD_SHARD.fetch_add(1, Ordering::Relaxed) as usize % n_shards;
            cell.set(assigned);
            assigned
        }
        shard => shard,
    })
}

struct RegisteredMetrics {
    metrics: Vec<MetricSlot>,
    // All distinct `boundaries/1` results referenced by any Distribution
    // metric, concatenated and deduplicated once at registration time -
    // many Distributions share the same bucket config (e.g. the default
    // `Peep.Buckets.Exponential` settings), so this avoids both the
    // redundant per-metric allocations and, more speculatively, keeps the
    // (small, frequently re-read) boundary data concentrated in fewer
    // cache lines than N private copies would. Shared across shards - it's
    // read-only after registration, so there's no contention to shard away.
    boundaries_arena: Box<[f64]>,
}

enum MetricSlot {
    Counter(Counters),
    Sum(Counters),
    LastValue(LastValues),
    Distribution(Distributions),
}

/// Figures out which `MetricSlot` a `Telemetry.Metrics` struct term
/// corresponds to, by checking its `__struct__` field. For a Distribution,
/// also interns its `:peep_bucket_boundaries` into the shared arena being
/// built up over the course of `register_metrics`.
fn metric_slot_for(
    metric: Term,
    arena: &mut Vec<f64>,
    interned: &mut Vec<(Vec<f64>, usize)>,
    n_shards: usize,
) -> MetricSlot {
    let struct_name: Atom = metric
        .map_get(rustler::types::atom::__struct__())
        .expect("metric must be a struct")
        .decode()
        .expect("__struct__ must be an atom");

    if struct_name == metric_atoms::counter() {
        MetricSlot::Counter(Counters::new(n_shards))
    } else if struct_name == metric_atoms::sum() {
        MetricSlot::Sum(Counters::new(n_shards))
    } else if struct_name == metric_atoms::last_value() {
        MetricSlot::LastValue(LastValues::new(n_shards))
    } else if struct_name == metric_atoms::distribution() {
        let boundaries: Vec<f64> = metric
            .map_get(metric_atoms::peep_bucket_boundaries())
            .expect("Distribution metric must carry :peep_bucket_boundaries")
            .decode()
            .expect(":peep_bucket_boundaries must be a list of numbers");

        let bounds = intern_boundaries(arena, interned, boundaries);
        MetricSlot::Distribution(Distributions::new(bounds, n_shards))
    } else {
        panic!("unrecognized metric struct: {struct_name:?}")
    }
}

/// Appends `boundaries` to `arena` unless an identical `Vec<f64>` has
/// already been interned, in which case its existing `(offset, len)` is
/// reused. Only called during `register_metrics`, so a linear scan over
/// `interned` (rather than a hash-based lookup) is plenty - the number of
/// *distinct* Distribution metrics in a single Peep instance is never going
/// to be large enough for this to matter, and it avoids re-deriving a hash
/// for `Vec<f64>` (which, unlike our tags machinery, has no BEAM term to
/// borrow a precomputed hash from).
///
/// Comparing against `interned`'s own owned copies (rather than scanning
/// the concatenated `arena` for a matching contiguous run) is deliberate:
/// two unrelated boundary sets placed back to back in `arena` could
/// otherwise coincidentally contain a matching subsequence that was never
/// actually a real, registered boundaries list on its own.
fn intern_boundaries(
    arena: &mut Vec<f64>,
    interned: &mut Vec<(Vec<f64>, usize)>,
    boundaries: Vec<f64>,
) -> (usize, usize) {
    if let Some((existing, offset)) = interned.iter().find(|(existing, _)| existing == &boundaries) {
        return (*offset, existing.len());
    }

    let offset = arena.len();
    arena.extend_from_slice(&boundaries);
    let len = boundaries.len();
    interned.push((boundaries, offset));
    (offset, len)
}

#[rustler::resource_impl]
impl Resource for Storage {}

/// A single tag's value, decoded into an owned, `'static` representation
/// so it can be stored in `Storage` past the lifetime of the NIF call that
/// produced it.
///
/// `Atom` needs no copying here: atoms are interned VM-wide, so an `Atom`
/// handle is already `Send + Sync + 'static` on its own. Only binaries
/// (`Str`) require an actual allocation.
#[derive(Clone, Debug)]
enum TagValue {
    Atom(Atom),
    Str(Box<str>),
    Int(i64),
    Float(u64), // f64::to_bits, so it can be Eq/Hash
}

impl PartialEq for TagValue {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (TagValue::Atom(a), TagValue::Atom(b)) => a == b,
            (TagValue::Str(a), TagValue::Str(b)) => a == b,
            (TagValue::Int(a), TagValue::Int(b)) => a == b,
            (TagValue::Float(a), TagValue::Float(b)) => a == b,
            _ => false,
        }
    }
}
impl Eq for TagValue {}

impl Hash for TagValue {
    fn hash<H: Hasher>(&self, state: &mut H) {
        match self {
            TagValue::Atom(a) => a.hash(state),
            TagValue::Str(s) => s.hash(state),
            TagValue::Int(i) => i.hash(state),
            TagValue::Float(bits) => bits.hash(state),
        }
    }
}

impl TagValue {
    /// Decodes a tag value term into an owned `TagValue`. Only called on
    /// the miss path, once per never-before-seen tags map.
    fn decode(term: Term) -> Self {
        match term.get_type() {
            TermType::Atom => TagValue::Atom(term.decode().expect("tag value atom")),
            TermType::Binary => {
                TagValue::Str(term.decode::<String>().expect("tag value binary").into())
            }
            TermType::Integer => TagValue::Int(term.decode().expect("tag value integer")),
            TermType::Float => {
                TagValue::Float(term.decode::<f64>().expect("tag value float").to_bits())
            }
            other => panic!("unsupported tag value type: {other:?}"),
        }
    }

    /// Compares this owned tag value against a (borrowed) term, without
    /// allocating. This is the hot path: called on every `insert_metric`
    /// for tags that have already been seen.
    fn matches(&self, term: Term) -> bool {
        match self {
            TagValue::Atom(a) => *a == term,
            TagValue::Str(s) => term.decode::<&str>().is_ok_and(|t| t == s.as_ref()),
            TagValue::Int(i) => term.decode::<i64>().is_ok_and(|t| t == *i),
            TagValue::Float(bits) => term.decode::<f64>().is_ok_and(|t| t.to_bits() == *bits),
        }
    }
}

/// Lets a `TagValue` be handed straight back to Elixir - used by
/// `LastValue`, which stores and later returns an arbitrary (well, whatever
/// `TagValue` covers) value rather than accumulating into a number.
impl Encoder for TagValue {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            TagValue::Atom(a) => a.encode(env),
            TagValue::Str(s) => s.as_ref().encode(env),
            TagValue::Int(i) => i.encode(env),
            TagValue::Float(bits) => f64::from_bits(*bits).encode(env),
        }
    }
}

/// An owned, `'static` representation of a tags map, used as a `HashMap`
/// key. Carries its own precomputed hash (from `Term::hash_internal`, the
/// same algorithm `Atom`'s `Hash` impl uses) so that `TermPassthroughHasher`
/// can make hashing a `TagsKey` reproduce exactly the hash we compute from
/// the incoming (borrowed) term at lookup time.
///
/// `Clone` is only needed for cross-shard merging in `get_all_metrics` -
/// nothing on the hot `insert_metric` path clones a `TagsKey`.
#[derive(Clone)]
struct TagsKey {
    hash: u64,
    pairs: Vec<(Atom, TagValue)>,
}

impl PartialEq for TagsKey {
    fn eq(&self, other: &Self) -> bool {
        self.pairs == other.pairs
    }
}
impl Eq for TagsKey {}

impl Hash for TagsKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        state.write_u64(self.hash);
    }
}

/// Decodes every pair out of a tags-shaped map term into owned pairs.
/// Shared by `build_tags_key` (the miss path, once per never-before-seen
/// tags map) and `prune_tags` (decoding its patterns, which have the same
/// shape but no hash to compute).
fn decode_tag_pairs(tags: Term) -> Vec<(Atom, TagValue)> {
    MapIterator::new(tags)
        .expect("tags must be a map")
        .map(|(key, value)| {
            let atom = Atom::from_term(key).expect("tag keys must be atoms");
            (atom, TagValue::decode(value))
        })
        .collect()
}

fn build_tags_key(tags: Term, hash: u64) -> TagsKey {
    TagsKey {
        hash,
        pairs: decode_tag_pairs(tags),
    }
}

/// The reverse of `build_tags_key`/`decode_tag_pairs`: turns an owned
/// `TagsKey` back into an Elixir map term. Only needed by `get_all_metrics`,
/// which is the one place that has to hand tags back to Elixir rather than
/// only ever comparing against a borrowed one.
fn encode_tags_key<'a>(env: Env<'a>, key: &TagsKey) -> Term<'a> {
    let mut keys = Vec::with_capacity(key.pairs.len());
    let mut values = Vec::with_capacity(key.pairs.len());
    for (atom, value) in &key.pairs {
        keys.push(atom.encode(env));
        values.push(value.encode(env));
    }
    Term::map_from_term_arrays(env, &keys, &values).expect("building tags map failed")
}

/// Structurally compares a (borrowed) tags term against an already-owned
/// `TagsKey`, without allocating. This is what lets lookups stay on the
/// read-lock-only path for tags that have already been seen.
fn tags_match(tags: Term, key: &TagsKey) -> bool {
    let Ok(size) = tags.map_size() else {
        return false;
    };
    if size != key.pairs.len() {
        return false;
    }

    key.pairs
        .iter()
        .all(|(name, value)| match tags.map_get(*name) {
            Ok(term) => value.matches(term),
            Err(_) => false,
        })
}

/// Heap bytes hanging off a `TagsKey` beyond its own `size_of`: the `pairs`
/// `Vec`'s backing allocation, plus any `TagValue::Str`'s own `Box<str>`
/// bytes (the only variable-length `TagValue` payload).
fn tags_key_heap_size(key: &TagsKey) -> usize {
    let pairs_backing = key.pairs.capacity() * size_of::<(Atom, TagValue)>();
    let str_bytes: usize = key
        .pairs
        .iter()
        .map(|(_, value)| match value {
            TagValue::Str(s) => s.len(),
            _ => 0,
        })
        .sum();
    pairs_backing + str_bytes
}

/// `size` (entry count) and an estimated `memory` (bytes) for one
/// `TagsKey`-keyed map: `capacity()` rather than `len()` for the table's own
/// backing allocation (hashbrown allocates ahead of `len`), plus each
/// entry's own heap data - `tags_key_heap_size` for the key, and
/// `value_heap_size` for whatever's variable-length about `V` (nothing, for
/// `AtomicI64`; the current `TagValue` for `Mutex<(i64, TagValue)>`; the
/// bucket array for `DistributionCell`). This intentionally doesn't try to
/// reproduce hashbrown's exact internal layout (e.g. its one-byte-per-slot
/// control metadata isn't part of its public API) - `storage_size/1` is
/// only ever asserted on for monotonicity, not an exact byte count.
fn map_size_and_memory<V>(
    map: &HashMap<TagsKey, V, TermHashBuilder>,
    value_heap_size: impl Fn(&V) -> usize,
) -> (usize, usize) {
    let mut memory = map.capacity() * (size_of::<TagsKey>() + size_of::<V>());
    for (key, value) in map.iter() {
        memory += tags_key_heap_size(key) + value_heap_size(value);
    }
    (map.len(), memory)
}

/// Sums `size`/`memory` across every shard of a sharded map, with no
/// attempt to deduplicate a `TagsKey` that happens to appear in more than
/// one shard - `Peep.Storage.Striped.storage_size/1` does the exact same
/// thing (summing `:ets.info(tid, :size)`/`:memory` across all of its
/// per-scheduler tables, no deduplication), so this matches that precedent
/// rather than inventing stricter semantics for a callback that's only
/// ever asserted on for monotonicity.
fn shards_size_and_memory<V>(
    shards: &[CachePadded<RwLock<HashMap<TagsKey, V, TermHashBuilder>>>],
    value_heap_size: impl Fn(&V) -> usize + Copy,
) -> (usize, usize) {
    let mut total_size = 0;
    let mut total_memory = 0;
    for shard in shards {
        let (size, memory) = map_size_and_memory(&shard.read().unwrap(), value_heap_size);
        total_size += size;
        total_memory += memory;
    }
    (total_size, total_memory)
}

/// Pads `T` out to a full cache line (64 bytes - the line size on every
/// mainstream x86-64 CPU, which is what this crate targets). Used for
/// per-shard `RwLock`s: `size_of::<RwLock<TagsMap>>()` is 48 bytes, which
/// doesn't evenly divide 64, so a plain `Box<[RwLock<TagsMap>]>` packs most
/// adjacent shard pairs onto the same cache line - meaning cores touching
/// *different*, logically-independent shards would still invalidate each
/// other's cached copy of that line on every lock acquire, largely
/// defeating the point of sharding by scheduler in the first place. Padding
/// each shard to its own line guarantees that can't happen.
#[repr(align(64))]
struct CachePadded<T>(T);

impl<T> std::ops::Deref for CachePadded<T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.0
    }
}

/// A `Hasher` that never actually hashes anything: it just remembers the
/// single `u64` written to it via `write_u64`. Paired with `TagsKey`'s
/// `Hash` impl (which only ever calls `write_u64(self.hash)`), this makes
/// hashbrown's internal insert-time hash of a `TagsKey` reproduce exactly
/// the hash we compute externally from the incoming term via
/// `Term::hash_internal`, so search-time and insert-time hashes always
/// agree.
#[derive(Default)]
struct TermPassthroughHasher(u64);

impl Hasher for TermPassthroughHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, _bytes: &[u8]) {
        unreachable!("TagsKey/Atom/TagValue must only hash via write_u64/write_i64/write_u32")
    }

    fn write_u64(&mut self, value: u64) {
        self.0 = value;
    }
}

type TermHashBuilder = BuildHasherDefault<TermPassthroughHasher>;
type TagsMap = HashMap<TagsKey, AtomicI64, TermHashBuilder>;

/// Shared by `Counter` and `Sum`. Sharded by scheduler: each shard is an
/// entirely independent map, so two writers on different schedulers never
/// contend on the same `RwLock` or the same `AtomicI64`, even when they're
/// incrementing "the same" (metric, tags) combination - mirroring how
/// `Peep.Storage.Striped` gives each scheduler its own ETS table, and how
/// `Peep.Storage.ETS` shards Counter/Sum specifically via a
/// `{id, tags, scheduler_id}` key. `insert_metric` is handed its
/// `shard_id` once per event (via `resolve/1`), not re-derived per metric.
struct Counters {
    shards: Box<[CachePadded<RwLock<TagsMap>>]>,
}

impl Counters {
    fn new(n_shards: usize) -> Self {
        let shards = (0..n_shards)
            .map(|_| CachePadded(RwLock::new(HashMap::default())))
            .collect();
        Counters { shards }
    }

    /// `delta` is signed because `Sum` metrics can legitimately decrease
    /// (e.g. `+1`/`-1` for something like an active-connection count) -
    /// same reason `Peep.Storage.ETS` passes signed values straight through
    /// to `:ets.update_counter/4`. `Counter` always calls this with `1`.
    fn increment(&self, shard_id: usize, tags: Term, hash: u64, delta: i64) {
        let map_lock = &self.shards[shard_id];

        // Fast path: tags we've already seen. Read lock only - the
        // `&AtomicI64` we get back is borrowed from the guard, so the
        // borrow checker guarantees nothing can move it out from under us
        // while we hold the guard (e.g. via a concurrent resize).
        {
            let values = map_lock.read().unwrap();
            if let Some((_, counter)) = values.raw_entry().from_hash(hash, |key| tags_match(tags, key)) {
                counter.fetch_add(delta, Ordering::Relaxed);
                return;
            }
        }

        // Slow path: first time we've seen these tags (on this shard).
        // Re-check under the write lock, since another thread on the same
        // scheduler may have inserted the same tags between us dropping
        // the read lock above and acquiring this one.
        let mut values = map_lock.write().unwrap();
        let (_, counter) = values
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
        counter.fetch_add(delta, Ordering::Relaxed);
    }
}

// The stored timestamp (nanoseconds, from `monotonic_time_ns`) is what lets
// `get_all_metrics` pick the genuinely most-recent write across shards -
// shard iteration order during a merge says nothing about wall-clock
// recency, so without it "last write wins" wouldn't hold once writes are
// sharded across independent maps. Mirrors `Peep.Storage.Striped`'s own
// `{now, value}` entries for exactly the same reason.
type LastValueMap = HashMap<TagsKey, Mutex<(i64, TagValue)>, TermHashBuilder>;

/// Sharded the same way `Counters` is, and for the same reason (eliminate
/// cross-scheduler contention on the same tags combination) - see
/// `Counters`'s doc comment.
struct LastValues {
    shards: Box<[CachePadded<RwLock<LastValueMap>>]>,
}

impl LastValues {
    fn new(n_shards: usize) -> Self {
        let shards = (0..n_shards)
            .map(|_| CachePadded(RwLock::new(HashMap::default())))
            .collect();
        LastValues { shards }
    }

    /// Unlike `Counters::increment`, this can't stop at "found an existing
    /// entry, mutate it in place" via `or_insert_with` on the slow path:
    /// for a last-write-wins metric, losing the race to create the entry
    /// still means *our* value has to end up stored, not the other
    /// thread's. So the slow path matches `Occupied`/`Vacant` explicitly
    /// and always writes `value` either way.
    fn set(&self, shard_id: usize, tags: Term, hash: u64, value: TagValue) {
        let map_lock = &self.shards[shard_id];
        let timestamp = monotonic_time_ns();

        // Fast path: tags already known (on this shard). Read lock on the
        // outer map only - the per-entry `Mutex` is what actually gets
        // replaced.
        {
            let values = map_lock.read().unwrap();
            if let Some((_, cell)) = values
                .raw_entry()
                .from_hash(hash, |key| tags_match(tags, key))
            {
                *cell.lock().unwrap() = (timestamp, value);
                return;
            }
        }

        // Slow path: first time we've seen these tags on this shard, or a
        // race with another thread's insert of the same tags. Either way
        // we already hold the write lock exclusively here, so
        // `Mutex::get_mut` (no locking, just the borrow checker's
        // exclusivity) is enough.
        let mut values = map_lock.write().unwrap();
        match values
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
        {
            RawEntryMut::Occupied(entry) => {
                *entry.into_mut().get_mut().unwrap() = (timestamp, value);
            }
            RawEntryMut::Vacant(entry) => {
                entry.insert(build_tags_key(tags, hash), Mutex::new((timestamp, value)));
            }
        }
    }
}

/// Per-tags-combination histogram state: one atomic counter per bucket
/// (`buckets.len() == boundaries.len() + 1`, the extra slot being the
/// `:infinity`/above-max overflow bucket), plus a running sum - the same
/// three-part shape as `Peep.Storage.Atomics`.
struct DistributionCell {
    buckets: Box<[AtomicU64]>,
    sum: AtomicI64,
}

impl DistributionCell {
    fn new(num_boundaries: usize) -> Self {
        let buckets: Box<[AtomicU64]> = (0..=num_boundaries).map(|_| AtomicU64::new(0)).collect();
        DistributionCell {
            buckets,
            sum: AtomicI64::new(0),
        }
    }

    /// `boundaries` is sorted, and `value < boundaries[i]` is what assigns
    /// a measurement to bucket `i` (matching `Peep.Buckets.Custom`'s own
    /// `val < boundary` clauses, and `Peep.Buckets.Exponential`'s
    /// equivalent `ceil(log(value)/log_gamma)` threshold). So the target
    /// bucket is the index of the first boundary strictly greater than
    /// `value` - exactly `partition_point`'s definition when partitioned on
    /// `boundary <= value`. If every boundary is `<= value`,
    /// `partition_point` returns `boundaries.len()`, which is exactly the
    /// overflow slot's index.
    fn record(&self, boundaries: &[f64], value: f64) {
        let idx = boundaries.partition_point(|&boundary| boundary <= value);
        self.buckets[idx].fetch_add(1, Ordering::Relaxed);
        self.sum.fetch_add(value.round() as i64, Ordering::Relaxed);
    }
}

type DistributionMap = HashMap<TagsKey, DistributionCell, TermHashBuilder>;

/// Sharded the same way `Counters` is, and for the same reason - see
/// `Counters`'s doc comment. `boundaries` (an index into the shared,
/// unsharded `boundaries_arena`) stays metric-level, not per-shard: it's
/// read-only config, not mutable state, so there's no contention on it to
/// eliminate.
struct Distributions {
    boundaries: (usize, usize),
    shards: Box<[CachePadded<RwLock<DistributionMap>>]>,
}

impl Distributions {
    fn new(boundaries: (usize, usize), n_shards: usize) -> Self {
        let shards = (0..n_shards)
            .map(|_| CachePadded(RwLock::new(HashMap::default())))
            .collect();
        Distributions { boundaries, shards }
    }

    /// Unlike `LastValues::set`, this can use the same `or_insert_with`
    /// shape as `Counters::increment` on the slow path: recording a
    /// measurement always *accumulates* into a cell, so "someone else
    /// already created this entry, record into it" is correct regardless
    /// of who won the race to create it.
    fn insert(&self, shard_id: usize, arena: &[f64], tags: Term, hash: u64, value: f64) {
        let (offset, len) = self.boundaries;
        let boundaries = &arena[offset..offset + len];
        let map_lock = &self.shards[shard_id];

        // Fast path: tags we've already seen (on this shard). Read lock
        // only - `record` only ever touches already-allocated atomics,
        // never the map itself, so this never needs to upgrade to a write
        // lock.
        {
            let values = map_lock.read().unwrap();
            if let Some((_, cell)) = values
                .raw_entry()
                .from_hash(hash, |key| tags_match(tags, key))
            {
                cell.record(boundaries, value);
                return;
            }
        }

        // Slow path: first time we've seen these tags on this shard.
        let mut values = map_lock.write().unwrap();
        let (_, cell) = values
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), DistributionCell::new(len)));
        cell.record(boundaries, value);
    }
}

#[rustler::nif]
fn new(_opts: Term) -> ResourceArc<Storage> {
    ResourceArc::new(Storage {
        registered: OnceLock::new(),
        unsync: OnceLock::new(),
    })
}

#[rustler::nif]
fn register_metrics(storage: &Storage, ids_to_metrics: Term) -> Atom {
    let n_shards = scheduler_count();
    let mut boundaries_arena: Vec<f64> = Vec::new();
    let mut interned: Vec<(Vec<f64>, usize)> = Vec::new();

    let metrics = get_tuple(ids_to_metrics)
        .expect("ids_to_metrics must be a tuple")
        .into_iter()
        .map(|metric| metric_slot_for(metric, &mut boundaries_arena, &mut interned, n_shards))
        .collect();

    let registered = RegisteredMetrics {
        metrics,
        boundaries_arena: boundaries_arena.into_boxed_slice(),
    };

    let n_metrics = registered.metrics.len();

    storage
        .registered
        .set(registered)
        .unwrap_or_else(|_| panic!("register_metrics must only be called once"));

    let _ = storage.unsync.set(UnsyncSlots::new(n_metrics, n_shards));

    rustler::types::atom::ok()
}

#[derive(NifMap)]
struct StorageSize {
    size: usize,
    memory: usize,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn storage_size(storage: &Storage) -> StorageSize {
    let Some(registered) = storage.registered.get() else {
        return StorageSize { size: 0, memory: 0 };
    };

    let mut size = 0;
    let mut memory =
        size_of::<RegisteredMetrics>() + registered.boundaries_arena.len() * size_of::<f64>();

    for slot in &registered.metrics {
        let (slot_size, slot_memory) = match slot {
            MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => {
                shards_size_and_memory(&counters.shards, |_| 0)
            }
            MetricSlot::LastValue(last_values) => shards_size_and_memory(&last_values.shards, |cell| {
                match &cell.lock().unwrap().1 {
                    TagValue::Str(s) => s.len(),
                    _ => 0,
                }
            }),
            MetricSlot::Distribution(distributions) => {
                shards_size_and_memory(&distributions.shards, |cell| {
                    cell.buckets.len() * size_of::<AtomicU64>()
                })
            }
        };

        size += slot_size;
        memory += slot_memory;
    }

    StorageSize { size, memory }
}

/// The per-sample work shared by `insert_metric` and the batched prototypes:
/// everything after the id/value/tags/hash for one sample are in hand.
#[inline]
fn store_one(
    registered: &RegisteredMetrics,
    shard_id: usize,
    id: usize,
    value: Term,
    tags: Term,
    hash: u64,
) {
    match registered.metrics.get(id) {
        Some(MetricSlot::Counter(counters)) => counters.increment(shard_id, tags, hash, 1),
        Some(MetricSlot::Sum(counters)) => {
            let delta: i64 = value.decode().expect("sum value must be an integer");
            counters.increment(shard_id, tags, hash, delta);
        }
        Some(MetricSlot::LastValue(last_values)) => {
            last_values.set(shard_id, tags, hash, TagValue::decode(value));
        }
        Some(MetricSlot::Distribution(distributions)) => {
            let measurement: f64 = value.decode().expect("distribution value must be a number");
            distributions.insert(
                shard_id,
                &registered.boundaries_arena,
                tags,
                hash,
                measurement,
            );
        }
        None => panic!("no metric registered for id {id}"),
    }
}

#[rustler::nif]
fn insert_metric(
    resolved: (&Storage, usize),
    id: usize,
    _metric: Term,
    value: Term,
    tags: Term,
) -> Atom {
    let (storage, shard_id) = resolved;
    let registered = storage
        .registered
        .get()
        .expect("register_metrics must be called before insert_metric");

    store_one(registered, shard_id, id, value, tags, tags.hash_internal(0) as u64);

    rustler::types::atom::ok()
}

/// Prototype A: one NIF call per event, `batch` being a list of
/// `{id, value, tags}` tuples. Amortizes the call trap and the resource
/// decode across every sample in the event, but still hashes each sample's
/// tags map independently.
#[rustler::nif]
fn insert_metrics_flat(resolved: (&Storage, usize), batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let registered = storage
        .registered
        .get()
        .expect("register_metrics must be called before insert_metrics");

    // `Term::decode` into a Rust tuple, *not* `get_tuple` - the latter
    // allocates a `Vec<Term>` per item, which on this path is a malloc per
    // metric per event.
    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, value, tags): (usize, Term, Term) =
            item.decode().expect("batch items must be {id, value, tags} tuples");
        store_one(registered, shard_id, id, value, tags, tags.hash_internal(0) as u64);
    }

    rustler::types::atom::ok()
}

/// Prototype C: like A, but the event's distinct tags maps are passed once,
/// as a tuple, and each batch item references one by index - so a tags map
/// shared by several metrics in the same event is hashed once rather than
/// once per metric. Mirrors the `tag_fns`/`tag_idx` deduplication
/// `Peep.Handler.Config` already does on the Elixir side.
#[rustler::nif]
fn insert_metrics_tagged(resolved: (&Storage, usize), tag_results: Term, batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let registered = storage
        .registered
        .get()
        .expect("register_metrics must be called before insert_metrics");

    // Borrowed straight from the term, no `Vec` - see `insert_metrics_flat`.
    let env = tag_results.get_env();
    let tag_terms =
        match unsafe { rustler::wrapper::tuple::get_tuple(env.as_c_arg(), tag_results.as_c_arg()) } {
            Ok(terms) => terms,
            Err(_) => panic!("tag_results must be a tuple"),
        };

    // Lazily-filled hash cache, one slot per distinct tags map. `u64::MAX`
    // is the "not yet computed" sentinel; a real hash colliding with it just
    // means recomputing, which is harmless. Kept small and stack-allocated -
    // an event with more than 8 *distinct* tags configurations falls back to
    // hashing per sample rather than paying to zero a larger array on every
    // event.
    let mut hashes = [u64::MAX; 8];

    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, value, tag_idx): (usize, Term, usize) =
            item.decode().expect("batch items must be {id, value, tag_idx} tuples");

        let tags = unsafe { Term::new(env, tag_terms[tag_idx]) };

        let hash = if tag_idx < hashes.len() {
            if hashes[tag_idx] == u64::MAX {
                hashes[tag_idx] = tags.hash_internal(0) as u64;
            }
            hashes[tag_idx]
        } else {
            tags.hash_internal(0) as u64
        };

        store_one(registered, shard_id, id, value, tags, hash);
    }

    rustler::types::atom::ok()
}

// Prices the synchronization on the Counter hot path: same hash, same
// hashbrown probe, same `tags_match`, but with the per-shard `RwLock`
// removed - and, in the `plain` variant, the atomic RMW replaced by an
// ordinary `+= 1`. This is the ceiling on what "one Storage per scheduler
// thread, no locks, no atomics" could buy.

#[rustler::nif]
fn insert_counter_unlocked_atomic(resolved: (&Storage, usize), id: usize, tags: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");
    let cell = &slots.unlocked_atomic[id][shard_id].0;
    let hash = tags.hash_internal(0) as u64;

    // SAFETY: measurement scaffolding, single-threaded by construction.
    let map = unsafe { &*cell.get() };
    if let Some((_, counter)) = map.raw_entry().from_hash(hash, |key| tags_match(tags, key)) {
        counter.fetch_add(1, Ordering::Relaxed);
        return rustler::types::atom::ok();
    }

    let map = unsafe { &mut *cell.get() };
    let (_, counter) = map
        .raw_entry_mut()
        .from_hash(hash, |key| tags_match(tags, key))
        .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
    counter.fetch_add(1, Ordering::Relaxed);

    rustler::types::atom::ok()
}

#[rustler::nif]
fn insert_counter_unlocked_plain(resolved: (&Storage, usize), id: usize, tags: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");
    let cell = &slots.unlocked_plain[id][shard_id].0;
    let hash = tags.hash_internal(0) as u64;

    // SAFETY: measurement scaffolding, single-threaded by construction.
    let map = unsafe { &mut *cell.get() };
    match map.raw_entry_mut().from_hash(hash, |key| tags_match(tags, key)) {
        RawEntryMut::Occupied(mut entry) => *entry.get_mut() += 1,
        RawEntryMut::Vacant(entry) => {
            entry.insert(build_tags_key(tags, hash), 1);
        }
    }

    rustler::types::atom::ok()
}

/// The same three variants, batched, so the synchronization cost can also be
/// read against the (much lower) per-metric cost of the batched path.
#[rustler::nif]
fn insert_counters_unlocked_plain(resolved: (&Storage, usize), batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");

    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, _value, tags): (usize, Term, Term) = item.decode().expect("batch item");
        let cell = &slots.unlocked_plain[id][shard_id].0;
        let hash = tags.hash_internal(0) as u64;

        // SAFETY: measurement scaffolding, single-threaded by construction.
        let map = unsafe { &mut *cell.get() };
        match map.raw_entry_mut().from_hash(hash, |key| tags_match(tags, key)) {
            RawEntryMut::Occupied(mut entry) => *entry.get_mut() += 1,
            RawEntryMut::Vacant(entry) => {
                entry.insert(build_tags_key(tags, hash), 1);
            }
        }
    }

    rustler::types::atom::ok()
}

/// Batched, no `RwLock`, values still `AtomicI64` - the middle term that
/// separates the lock's contended cost from the atomic's.
#[rustler::nif]
fn insert_counters_unlocked_atomic(resolved: (&Storage, usize), batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");

    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, _value, tags): (usize, Term, Term) = item.decode().expect("batch item");
        let cell = &slots.unlocked_atomic[id][shard_id];
        let hash = tags.hash_internal(0) as u64;

        // SAFETY: measurement scaffolding, see `UnsyncSlots`.
        let map = unsafe { &*cell.get() };
        if let Some((_, counter)) = map.raw_entry().from_hash(hash, |key| tags_match(tags, key)) {
            counter.fetch_add(1, Ordering::Relaxed);
            continue;
        }

        let map = unsafe { &mut *cell.get() };
        let (_, counter) = map
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
        counter.fetch_add(1, Ordering::Relaxed);
    }

    rustler::types::atom::ok()
}

/// Byte-for-byte `insert_counters_unlocked_atomic`, plus a read guard on a
/// lock that protects nothing. Differencing the two isolates the cost of
/// `RwLock::read` + guard drop from every other difference between the real
/// and shadow paths.
#[rustler::nif]
fn insert_counters_dummy_locked(resolved: (&Storage, usize), batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");

    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, _value, tags): (usize, Term, Term) = item.decode().expect("batch item");
        let _guard = slots.dummy_locks[id][shard_id].read().unwrap();

        let cell = &slots.unlocked_atomic[id][shard_id];
        let hash = tags.hash_internal(0) as u64;

        // SAFETY: measurement scaffolding, see `UnsyncSlots`.
        let map = unsafe { &*cell.get() };
        if let Some((_, counter)) = map.raw_entry().from_hash(hash, |key| tags_match(tags, key)) {
            counter.fetch_add(1, Ordering::Relaxed);
            continue;
        }

        let map = unsafe { &mut *cell.get() };
        let (_, counter) = map
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
        counter.fetch_add(1, Ordering::Relaxed);
    }

    rustler::types::atom::ok()
}

/// `insert_counters_dummy_locked` with `parking_lot::RwLock` in place of
/// std's.
#[rustler::nif]
fn insert_counters_pl_locked(resolved: (&Storage, usize), batch: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let slots = storage.unsync.get().expect("register_metrics must be called first");

    for item in batch.into_list_iterator().expect("batch must be a list") {
        let (id, _value, tags): (usize, Term, Term) = item.decode().expect("batch item");
        let _guard = slots.dummy_pl_locks[id][shard_id].read();

        let cell = &slots.unlocked_atomic[id][shard_id];
        let hash = tags.hash_internal(0) as u64;

        // SAFETY: measurement scaffolding, see `UnsyncSlots`.
        let map = unsafe { &*cell.get() };
        if let Some((_, counter)) = map.raw_entry().from_hash(hash, |key| tags_match(tags, key)) {
            counter.fetch_add(1, Ordering::Relaxed);
            continue;
        }

        let map = unsafe { &mut *cell.get() };
        let (_, counter) = map
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
        counter.fetch_add(1, Ordering::Relaxed);
    }

    rustler::types::atom::ok()
}

/// A Counter insert whose shard comes from a Rust `thread_local!` rather than
/// from Elixir's `resolve/1`, so `insert_metric`'s first argument can be a
/// bare resource instead of a `{resource, shard_id}` tuple. Prices both the
/// thread-local read and the tuple decode it replaces.
#[rustler::nif]
fn insert_counter_thread_local(storage: &Storage, id: usize, tags: Term) -> Atom {
    let registered = storage.registered.get().expect("register_metrics must be called first");
    let shard_id = thread_shard(scheduler_count());

    if let Some(MetricSlot::Counter(counters)) = registered.metrics.get(id) {
        counters.increment(shard_id, tags, tags.hash_internal(0) as u64, 1);
    }

    rustler::types::atom::ok()
}

/// Just the thread-local read, to separate it from the insert work above.
#[rustler::nif]
fn debug_thread_local(_storage: &Storage) -> Atom {
    std::hint::black_box(thread_shard(64));
    rustler::types::atom::ok()
}

/// Reports the calling OS thread's own shard index, plus what
/// `enif_thread_type` says this thread is. Used to check the linchpin of a
/// truly lock-free design: that a process pinned to scheduler K via
/// `spawn_opt(scheduler: K)` always lands on the same OS thread, so a
/// scheduler-pinned collector can read that thread's storage with no
/// synchronization at all.
#[rustler::nif]
fn debug_thread_shard() -> (usize, i32) {
    (
        thread_shard(1024),
        unsafe { rustler::sys::enif_thread_type() },
    )
}

// Temporary diagnostics, not part of `Peep.Storage`: peel back each layer
// of the Counter hot path one at a time, to find where its ~100ns
// (uncontended) latency actually goes. Delete after use.

#[rustler::nif]
fn debug_bare() -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_decode_args(
    _resolved: (&Storage, usize),
    _id: usize,
    _metric: Term,
    _value: Term,
    _tags: Term,
) -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_decode_resolved_only(_resolved: (&Storage, usize)) -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_decode_storage_plain(_storage: &Storage) -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_decode_id_only(_id: usize) -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_decode_terms_only(_metric: Term, _value: Term, _tags: Term) -> Atom {
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_hash_tags(
    _resolved: (&Storage, usize),
    _id: usize,
    _metric: Term,
    _value: Term,
    tags: Term,
) -> Atom {
    let _hash = tags.hash_internal(0);
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_rwlock_only(resolved: (&Storage, usize), id: usize, _metric: Term, _value: Term, _tags: Term) -> Atom {
    let (storage, shard_id) = resolved;
    let registered = storage.registered.get().expect("register_metrics must be called first");
    if let Some(MetricSlot::Counter(counters)) = registered.metrics.get(id) {
        let _guard = counters.shards[shard_id].read().unwrap();
    }
    rustler::types::atom::ok()
}

#[rustler::nif]
fn debug_lookup_no_atomic(
    resolved: (&Storage, usize),
    id: usize,
    _metric: Term,
    _value: Term,
    tags: Term,
) -> Atom {
    let (storage, shard_id) = resolved;
    let registered = storage.registered.get().expect("register_metrics must be called first");
    if let Some(MetricSlot::Counter(counters)) = registered.metrics.get(id) {
        let hash = tags.hash_internal(0) as u64;
        let values = counters.shards[shard_id].read().unwrap();
        let _ = values.raw_entry().from_hash(hash, |key| tags_match(tags, key));
    }
    rustler::types::atom::ok()
}

/// Builds the final `%{tags => value}` map for a `Counter`/`Sum` slot,
/// summing each `TagsKey`'s value across every shard it appears in.
fn encode_counter_map<'a>(env: Env<'a>, counters: &Counters) -> (usize, Term<'a>) {
    let mut combined: HashMap<TagsKey, i64, TermHashBuilder> = HashMap::default();
    for shard in &counters.shards {
        for (key, counter) in shard.read().unwrap().iter() {
            let value = counter.load(Ordering::Relaxed);
            combined
                .entry(key.clone())
                .and_modify(|total| *total += value)
                .or_insert(value);
        }
    }

    let mut keys = Vec::with_capacity(combined.len());
    let mut vals = Vec::with_capacity(combined.len());
    for (key, value) in &combined {
        keys.push(encode_tags_key(env, key));
        vals.push(value.encode(env));
    }
    let map = Term::map_from_term_arrays(env, &keys, &vals).expect("building counter map failed");
    (combined.len(), map)
}

/// Builds the final `%{tags => value}` map for a `LastValue` slot, keeping
/// whichever shard's entry has the largest timestamp for each `TagsKey` -
/// see `LastValueMap`'s doc comment for why that's necessary.
fn encode_last_value_map<'a>(env: Env<'a>, last_values: &LastValues) -> (usize, Term<'a>) {
    let mut combined: HashMap<TagsKey, (i64, TagValue), TermHashBuilder> = HashMap::default();
    for shard in &last_values.shards {
        for (key, cell) in shard.read().unwrap().iter() {
            let guard = cell.lock().unwrap();
            let (timestamp, value) = (guard.0, guard.1.clone());
            combined
                .entry(key.clone())
                .and_modify(|(existing_ts, existing_val)| {
                    if timestamp > *existing_ts {
                        *existing_ts = timestamp;
                        *existing_val = value.clone();
                    }
                })
                .or_insert((timestamp, value));
        }
    }

    let mut keys = Vec::with_capacity(combined.len());
    let mut vals = Vec::with_capacity(combined.len());
    for (key, (_, value)) in &combined {
        keys.push(encode_tags_key(env, key));
        vals.push(value.encode(env));
    }
    let map =
        Term::map_from_term_arrays(env, &keys, &vals).expect("building last_value map failed");
    (combined.len(), map)
}

/// Builds the `%{tags => buckets}` map for a `Distribution` slot, summing
/// each `TagsKey`'s buckets (and running sum) element-wise across every
/// shard it appears in - no ordering concern here, unlike `LastValue`,
/// since Distribution is accumulate-only. `buckets` is keyed by plain
/// integer bucket index plus `:infinity`/`:sum` - turning indices into the
/// real `"1.222222"`-style labels needs `Peep.Buckets`, i.e. arbitrary
/// Elixir, so that happens as a post-pass on the Elixir side
/// (`Peep.Storage.Rustler.get_all_metrics/2`), not here.
fn encode_distribution_map<'a>(env: Env<'a>, distributions: &Distributions) -> (usize, Term<'a>) {
    let mut combined: HashMap<TagsKey, (Vec<u64>, i64), TermHashBuilder> = HashMap::default();
    for shard in &distributions.shards {
        for (key, cell) in shard.read().unwrap().iter() {
            let buckets: Vec<u64> = cell.buckets.iter().map(|c| c.load(Ordering::Relaxed)).collect();
            let sum = cell.sum.load(Ordering::Relaxed);
            combined
                .entry(key.clone())
                .and_modify(|(existing_buckets, existing_sum)| {
                    for (existing, added) in existing_buckets.iter_mut().zip(&buckets) {
                        *existing += added;
                    }
                    *existing_sum += sum;
                })
                .or_insert((buckets, sum));
        }
    }

    let mut keys = Vec::with_capacity(combined.len());
    let mut vals = Vec::with_capacity(combined.len());
    for (key, (buckets, sum)) in &combined {
        keys.push(encode_tags_key(env, key));
        vals.push(encode_distribution_buckets(env, buckets, *sum));
    }
    let map =
        Term::map_from_term_arrays(env, &keys, &vals).expect("building distribution map failed");
    (combined.len(), map)
}

fn encode_distribution_buckets<'a>(env: Env<'a>, buckets: &[u64], sum: i64) -> Term<'a> {
    let overflow_idx = buckets.len() - 1;
    let mut keys = Vec::with_capacity(buckets.len() + 1);
    let mut vals = Vec::with_capacity(buckets.len() + 1);

    for (idx, count) in buckets.iter().enumerate() {
        let key = if idx == overflow_idx {
            output_atoms::infinity().encode(env)
        } else {
            (idx as u64).encode(env)
        };
        keys.push(key);
        vals.push(count.encode(env));
    }

    keys.push(output_atoms::sum().encode(env));
    vals.push(sum.encode(env));

    Term::map_from_term_arrays(env, &keys, &vals).expect("building distribution bucket map failed")
}

/// Called by `Peep.Storage.Rustler.get_all_metrics/2`, which has already
/// pulled `ids_to_metrics` out of the `:persistent` record on the Elixir
/// side - see that module for why. `ids_to_metrics[id]` is the plain,
/// unaugmented metric struct (no `:peep_bucket_boundaries`), used as-is for
/// the outer map's keys. A metric with no stored entries (across all
/// shards) is omitted entirely, matching what `Peep.Storage.ETS` does (it
/// only ever iterates real `:ets` rows).
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_get_all_metrics<'a>(storage: &Storage, ids_to_metrics: Term<'a>) -> Term<'a> {
    let env = ids_to_metrics.get_env();

    let Some(registered) = storage.registered.get() else {
        return Term::map_new(env);
    };

    let metric_terms = get_tuple(ids_to_metrics).expect("ids_to_metrics must be a tuple");

    let mut outer_keys = Vec::new();
    let mut outer_vals = Vec::new();

    for (metric_term, slot) in metric_terms.iter().zip(&registered.metrics) {
        let (len, inner) = match slot {
            MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => {
                encode_counter_map(env, counters)
            }
            MetricSlot::LastValue(last_values) => encode_last_value_map(env, last_values),
            MetricSlot::Distribution(distributions) => {
                encode_distribution_map(env, distributions)
            }
        };

        if len > 0 {
            outer_keys.push(*metric_term);
            outer_vals.push(inner);
        }
    }

    Term::map_from_term_arrays(env, &outer_keys, &outer_vals).expect("building result map failed")
}

fn matches_any_pattern(key: &TagsKey, patterns: &[Vec<(Atom, TagValue)>]) -> bool {
    patterns.iter().any(|pattern| {
        pattern
            .iter()
            .all(|(atom, value)| key.pairs.iter().any(|(k, v)| k == atom && v == value))
    })
}

/// Removes every entry whose tags contain any of `patterns` as a subset
/// (not an exact match) - `%{foo: :bar}` matches both `%{foo: :bar}` and
/// `%{foo: :bar, baz: 1}`, mirroring `Peep.Storage.ETS`'s match-spec
/// semantics. Not hot-path, so a single write lock per shard for the whole
/// operation (rather than the read/write split `insert_metric` uses) is
/// fine - there's no concurrent-read case here worth optimizing for. No
/// merge concept needed here (unlike `get_all_metrics`): each shard's map
/// is filtered independently, matching how `Peep.Storage.Striped.prune_tags/2`
/// runs `:ets.select_delete/2` against each of its per-scheduler tables in
/// turn.
fn prune_map<V>(map: &mut HashMap<TagsKey, V, TermHashBuilder>, patterns: &[Vec<(Atom, TagValue)>]) {
    map.retain(|key, _| !matches_any_pattern(key, patterns));
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prune_tags(storage: &Storage, patterns: Term) -> Atom {
    if let Some(registered) = storage.registered.get() {
        let patterns: Vec<Term> = patterns.decode().expect("patterns must be a list");
        let patterns: Vec<Vec<(Atom, TagValue)>> = patterns.into_iter().map(decode_tag_pairs).collect();

        for slot in &registered.metrics {
            match slot {
                MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => {
                    for shard in &counters.shards {
                        prune_map(&mut shard.write().unwrap(), &patterns);
                    }
                }
                MetricSlot::LastValue(last_values) => {
                    for shard in &last_values.shards {
                        prune_map(&mut shard.write().unwrap(), &patterns);
                    }
                }
                MetricSlot::Distribution(distributions) => {
                    for shard in &distributions.shards {
                        prune_map(&mut shard.write().unwrap(), &patterns);
                    }
                }
            }
        }
    }

    rustler::types::atom::ok()
}

rustler::init!("Elixir.Peep.Storage.Rustler");
