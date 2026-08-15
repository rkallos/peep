use hashbrown::hash_map::{HashMap, RawEntryMut};
use rustler::types::map::MapIterator;
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Encoder, Env, NifMap, Resource, ResourceArc, Term, TermType};
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

struct Storage {
    // Populated once, by `register_metrics`, some time after `new` returns
    // the resource. `OnceLock` gives lock-free reads on the (extremely hot)
    // `insert_metric` path without needing a lock that's only ever
    // contended during that one-time setup.
    registered: OnceLock<RegisteredMetrics>,
}

struct RegisteredMetrics {
    metrics: Vec<MetricSlot>,
    // All distinct `boundaries/1` results referenced by any Distribution
    // metric, concatenated and deduplicated once at registration time -
    // many Distributions share the same bucket config (e.g. the default
    // `Peep.Buckets.Exponential` settings), so this avoids both the
    // redundant per-metric allocations and, more speculatively, keeps the
    // (small, frequently re-read) boundary data concentrated in fewer
    // cache lines than N private copies would.
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
) -> MetricSlot {
    let struct_name: Atom = metric
        .map_get(rustler::types::atom::__struct__())
        .expect("metric must be a struct")
        .decode()
        .expect("__struct__ must be an atom");

    if struct_name == metric_atoms::counter() {
        MetricSlot::Counter(Counters::new())
    } else if struct_name == metric_atoms::sum() {
        MetricSlot::Sum(Counters::new())
    } else if struct_name == metric_atoms::last_value() {
        MetricSlot::LastValue(LastValues::new())
    } else if struct_name == metric_atoms::distribution() {
        let boundaries: Vec<f64> = metric
            .map_get(metric_atoms::peep_bucket_boundaries())
            .expect("Distribution metric must carry :peep_bucket_boundaries")
            .decode()
            .expect(":peep_bucket_boundaries must be a list of numbers");

        let bounds = intern_boundaries(arena, interned, boundaries);
        MetricSlot::Distribution(Distributions::new(bounds))
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
/// `AtomicI64`; the current `TagValue` for `Mutex<TagValue>`; the bucket
/// array for `DistributionCell`). This intentionally doesn't try to
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

struct Counters {
    values: RwLock<TagsMap>,
}

impl Counters {
    fn new() -> Self {
        Counters {
            values: RwLock::new(HashMap::default()),
        }
    }

    /// `delta` is signed because `Sum` metrics can legitimately decrease
    /// (e.g. `+1`/`-1` for something like an active-connection count) -
    /// same reason `Peep.Storage.ETS` passes signed values straight through
    /// to `:ets.update_counter/4`. `Counter` always calls this with `1`.
    fn increment(&self, tags: Term, delta: i64) {
        let hash = tags.hash_internal(0) as u64;

        // Fast path: tags we've already seen. Read lock only - the
        // `&AtomicI64` we get back is borrowed from the guard, so the
        // borrow checker guarantees nothing can move it out from under us
        // while we hold the guard (e.g. via a concurrent resize).
        {
            let values = self.values.read().unwrap();
            if let Some((_, counter)) = values.raw_entry().from_hash(hash, |key| {
                tags_match(tags, key)
            }) {
                counter.fetch_add(delta, Ordering::Relaxed);
                return;
            }
        }

        // Slow path: first time we've seen these tags. Re-check under the
        // write lock, since another thread may have inserted the same tags
        // between us dropping the read lock above and acquiring this one.
        let mut values = self.values.write().unwrap();
        let (_, counter) = values
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
            .or_insert_with(|| (build_tags_key(tags, hash), AtomicI64::new(0)));
        counter.fetch_add(delta, Ordering::Relaxed);
    }
}

type LastValueMap = HashMap<TagsKey, Mutex<TagValue>, TermHashBuilder>;

struct LastValues {
    values: RwLock<LastValueMap>,
}

impl LastValues {
    fn new() -> Self {
        LastValues {
            values: RwLock::new(HashMap::default()),
        }
    }

    /// Unlike `Counters::increment`, this can't stop at "found an existing
    /// entry, mutate it in place" via `or_insert_with` on the slow path:
    /// for a last-write-wins metric, losing the race to create the entry
    /// still means *our* value has to end up stored, not the other
    /// thread's. So the slow path matches `Occupied`/`Vacant` explicitly
    /// and always writes `value` either way.
    fn set(&self, tags: Term, value: TagValue) {
        let hash = tags.hash_internal(0) as u64;

        // Fast path: tags already known. Read lock on the outer map only -
        // the per-entry `Mutex` is what actually gets replaced.
        {
            let values = self.values.read().unwrap();
            if let Some((_, cell)) = values
                .raw_entry()
                .from_hash(hash, |key| tags_match(tags, key))
            {
                *cell.lock().unwrap() = value;
                return;
            }
        }

        // Slow path: first time we've seen these tags, or a race with
        // another thread's insert of the same tags. Either way we already
        // hold the write lock exclusively here, so `Mutex::get_mut` (no
        // locking, just the borrow checker's exclusivity) is enough.
        let mut values = self.values.write().unwrap();
        match values
            .raw_entry_mut()
            .from_hash(hash, |key| tags_match(tags, key))
        {
            RawEntryMut::Occupied(entry) => {
                *entry.into_mut().get_mut().unwrap() = value;
            }
            RawEntryMut::Vacant(entry) => {
                entry.insert(build_tags_key(tags, hash), Mutex::new(value));
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

struct Distributions {
    // (offset, len) into `RegisteredMetrics::boundaries_arena`.
    boundaries: (usize, usize),
    values: RwLock<DistributionMap>,
}

impl Distributions {
    fn new(boundaries: (usize, usize)) -> Self {
        Distributions {
            boundaries,
            values: RwLock::new(HashMap::default()),
        }
    }

    /// Unlike `LastValues::set`, this can use the same `or_insert_with`
    /// shape as `Counters::increment` on the slow path: recording a
    /// measurement always *accumulates* into a cell, so "someone else
    /// already created this entry, record into it" is correct regardless
    /// of who won the race to create it.
    fn insert(&self, arena: &[f64], tags: Term, value: f64) {
        let (offset, len) = self.boundaries;
        let boundaries = &arena[offset..offset + len];

        let hash = tags.hash_internal(0) as u64;

        // Fast path: tags we've already seen. Read lock only - `record`
        // only ever touches already-allocated atomics, never the map
        // itself, so this never needs to upgrade to a write lock.
        {
            let values = self.values.read().unwrap();
            if let Some((_, cell)) = values
                .raw_entry()
                .from_hash(hash, |key| tags_match(tags, key))
            {
                cell.record(boundaries, value);
                return;
            }
        }

        // Slow path: first time we've seen these tags.
        let mut values = self.values.write().unwrap();
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
    })
}

#[rustler::nif]
fn register_metrics(storage: ResourceArc<Storage>, ids_to_metrics: Term) -> Atom {
    let mut boundaries_arena: Vec<f64> = Vec::new();
    let mut interned: Vec<(Vec<f64>, usize)> = Vec::new();

    let metrics = get_tuple(ids_to_metrics)
        .expect("ids_to_metrics must be a tuple")
        .into_iter()
        .map(|metric| metric_slot_for(metric, &mut boundaries_arena, &mut interned))
        .collect();

    let registered = RegisteredMetrics {
        metrics,
        boundaries_arena: boundaries_arena.into_boxed_slice(),
    };

    storage
        .registered
        .set(registered)
        .unwrap_or_else(|_| panic!("register_metrics must only be called once"));

    rustler::types::atom::ok()
}

#[derive(NifMap)]
struct StorageSize {
    size: usize,
    memory: usize,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn storage_size(storage: ResourceArc<Storage>) -> StorageSize {
    let Some(registered) = storage.registered.get() else {
        return StorageSize { size: 0, memory: 0 };
    };

    let mut size = 0;
    let mut memory =
        size_of::<RegisteredMetrics>() + registered.boundaries_arena.len() * size_of::<f64>();

    for slot in &registered.metrics {
        let (slot_size, slot_memory) = match slot {
            MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => {
                map_size_and_memory(&counters.values.read().unwrap(), |_| 0)
            }
            MetricSlot::LastValue(last_values) => {
                map_size_and_memory(&last_values.values.read().unwrap(), |cell| {
                    match &*cell.lock().unwrap() {
                        TagValue::Str(s) => s.len(),
                        _ => 0,
                    }
                })
            }
            MetricSlot::Distribution(distributions) => {
                map_size_and_memory(&distributions.values.read().unwrap(), |cell| {
                    cell.buckets.len() * size_of::<AtomicU64>()
                })
            }
        };

        size += slot_size;
        memory += slot_memory;
    }

    StorageSize { size, memory }
}

#[rustler::nif]
fn insert_metric(
    storage: ResourceArc<Storage>,
    id: usize,
    _metric: Term,
    value: Term,
    tags: Term,
) -> Atom {
    let registered = storage
        .registered
        .get()
        .expect("register_metrics must be called before insert_metric");

    match registered.metrics.get(id) {
        Some(MetricSlot::Counter(counters)) => counters.increment(tags, 1),
        Some(MetricSlot::Sum(counters)) => {
            let delta: i64 = value.decode().expect("sum value must be an integer");
            counters.increment(tags, delta);
        }
        Some(MetricSlot::LastValue(last_values)) => {
            last_values.set(tags, TagValue::decode(value));
        }
        Some(MetricSlot::Distribution(distributions)) => {
            let measurement: f64 = value.decode().expect("distribution value must be a number");
            distributions.insert(&registered.boundaries_arena, tags, measurement);
        }
        None => panic!("no metric registered for id {id}"),
    }

    rustler::types::atom::ok()
}

/// Builds the final `%{tags => value}` map for a `Counter`/`Sum` slot.
fn encode_counter_map<'a>(env: Env<'a>, counters: &Counters) -> Term<'a> {
    let values = counters.values.read().unwrap();
    let mut keys = Vec::with_capacity(values.len());
    let mut vals = Vec::with_capacity(values.len());
    for (key, counter) in values.iter() {
        keys.push(encode_tags_key(env, key));
        vals.push(counter.load(Ordering::Relaxed).encode(env));
    }
    Term::map_from_term_arrays(env, &keys, &vals).expect("building counter map failed")
}

/// Builds the final `%{tags => value}` map for a `LastValue` slot.
fn encode_last_value_map<'a>(env: Env<'a>, last_values: &LastValues) -> Term<'a> {
    let values = last_values.values.read().unwrap();
    let mut keys = Vec::with_capacity(values.len());
    let mut vals = Vec::with_capacity(values.len());
    for (key, cell) in values.iter() {
        keys.push(encode_tags_key(env, key));
        vals.push(cell.lock().unwrap().encode(env));
    }
    Term::map_from_term_arrays(env, &keys, &vals).expect("building last_value map failed")
}

/// Builds the `%{tags => buckets}` map for a `Distribution` slot. `buckets`
/// is keyed by plain integer bucket index plus `:infinity`/`:sum` - turning
/// indices into the real `"1.222222"`-style labels needs `Peep.Buckets`,
/// i.e. arbitrary Elixir, so that happens as a post-pass on the Elixir side
/// (`Peep.Storage.Rustler.get_all_metrics/2`), not here.
fn encode_distribution_map<'a>(env: Env<'a>, distributions: &Distributions) -> Term<'a> {
    let values = distributions.values.read().unwrap();
    let mut keys = Vec::with_capacity(values.len());
    let mut vals = Vec::with_capacity(values.len());
    for (tags_key, cell) in values.iter() {
        keys.push(encode_tags_key(env, tags_key));
        vals.push(encode_distribution_cell(env, cell));
    }
    Term::map_from_term_arrays(env, &keys, &vals).expect("building distribution map failed")
}

fn encode_distribution_cell<'a>(env: Env<'a>, cell: &DistributionCell) -> Term<'a> {
    let overflow_idx = cell.buckets.len() - 1;
    let mut keys = Vec::with_capacity(cell.buckets.len() + 1);
    let mut vals = Vec::with_capacity(cell.buckets.len() + 1);

    for (idx, counter) in cell.buckets.iter().enumerate() {
        let key = if idx == overflow_idx {
            output_atoms::infinity().encode(env)
        } else {
            (idx as u64).encode(env)
        };
        keys.push(key);
        vals.push(counter.load(Ordering::Relaxed).encode(env));
    }

    keys.push(output_atoms::sum().encode(env));
    vals.push(cell.sum.load(Ordering::Relaxed).encode(env));

    Term::map_from_term_arrays(env, &keys, &vals).expect("building distribution bucket map failed")
}

/// Called by `Peep.Storage.Rustler.get_all_metrics/2`, which has already
/// pulled `ids_to_metrics` out of the `:persistent` record on the Elixir
/// side - see that module for why. `ids_to_metrics[id]` is the plain,
/// unaugmented metric struct (no `:peep_bucket_boundaries`), used as-is for
/// the outer map's keys. A metric with no stored entries is omitted
/// entirely, matching what `Peep.Storage.ETS` does (it only ever iterates
/// real `:ets` rows).
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_get_all_metrics(storage: ResourceArc<Storage>, ids_to_metrics: Term) -> Term {
    let env = ids_to_metrics.get_env();

    let Some(registered) = storage.registered.get() else {
        return Term::map_new(env);
    };

    let metric_terms = get_tuple(ids_to_metrics).expect("ids_to_metrics must be a tuple");

    let mut outer_keys = Vec::new();
    let mut outer_vals = Vec::new();

    for (metric_term, slot) in metric_terms.iter().zip(&registered.metrics) {
        let (len, inner) = match slot {
            MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => (
                counters.values.read().unwrap().len(),
                encode_counter_map(env, counters),
            ),
            MetricSlot::LastValue(last_values) => (
                last_values.values.read().unwrap().len(),
                encode_last_value_map(env, last_values),
            ),
            MetricSlot::Distribution(distributions) => (
                distributions.values.read().unwrap().len(),
                encode_distribution_map(env, distributions),
            ),
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
/// semantics. Not hot-path, so a single write lock per slot for the whole
/// operation (rather than the read/write split `insert_metric` uses) is
/// fine - there's no concurrent-read case here worth optimizing for.
fn prune_map<V>(map: &mut HashMap<TagsKey, V, TermHashBuilder>, patterns: &[Vec<(Atom, TagValue)>]) {
    map.retain(|key, _| !matches_any_pattern(key, patterns));
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prune_tags(storage: ResourceArc<Storage>, patterns: Term) -> Atom {
    if let Some(registered) = storage.registered.get() {
        let patterns: Vec<Term> = patterns.decode().expect("patterns must be a list");
        let patterns: Vec<Vec<(Atom, TagValue)>> = patterns.into_iter().map(decode_tag_pairs).collect();

        for slot in &registered.metrics {
            match slot {
                MetricSlot::Counter(counters) | MetricSlot::Sum(counters) => {
                    prune_map(&mut counters.values.write().unwrap(), &patterns);
                }
                MetricSlot::LastValue(last_values) => {
                    prune_map(&mut last_values.values.write().unwrap(), &patterns);
                }
                MetricSlot::Distribution(distributions) => {
                    prune_map(&mut distributions.values.write().unwrap(), &patterns);
                }
            }
        }
    }

    rustler::types::atom::ok()
}

#[rustler::nif]
fn resolve(storage: Term) -> Term {
    storage
}

rustler::init!("Elixir.Peep.Storage.Rustler");
