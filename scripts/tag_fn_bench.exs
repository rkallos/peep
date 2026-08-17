# Prices alternatives to `Peep.Handler.Config.compile_tag_fn/2`'s
# `Map.take(tag_values.(metadata), keys)`, which perf showed at ~7.4% of
# cpu-clock samples in the batched profile:
#
#   Map:take/3                              4.54%
#   Map:take/2                              1.02%
#   flatmap_from_validated_list             1.11%
#   maps_from_list_1_helper_ycf_gen_yielding 0.77%
#
# Map.take/2 conses a {key, value} list and then calls :maps.from_list/1, which
# is why from_list shows up. Building the map directly from a pinned-key match
# should skip both the intermediate list and the from_list validation.

defmodule Loop do
  def run(_fun, 0), do: :ok

  def run(fun, n) do
    fun.()
    run(fun, n - 1)
  end

  def time(fun, n) do
    t0 = :erlang.monotonic_time(:nanosecond)
    run(fun, n)
    t1 = :erlang.monotonic_time(:nanosecond)
    (t1 - t0) / n
  end

  def best_of(fun, n, reps) do
    run(fun, n)
    1..reps |> Enum.map(fn _ -> time(fun, n) end) |> Enum.min()
  end
end

defmodule TagFns do
  # What compile_tag_fn/2 builds today.
  def current(tag_values, keys) do
    fn metadata -> Map.take(tag_values.(metadata), keys) end
  end

  # Specialized per arity. The pinned-key map pattern requires every key to be
  # present; when one is missing the semantics of Map.take (omit it) are
  # preserved by falling back.
  def specialized(tag_values, [k1]) do
    fn metadata ->
      case tag_values.(metadata) do
        %{^k1 => v1} -> %{k1 => v1}
        _ -> %{}
      end
    end
  end

  def specialized(tag_values, [k1, k2] = keys) do
    fn metadata ->
      case tag_values.(metadata) do
        %{^k1 => v1, ^k2 => v2} -> %{k1 => v1, k2 => v2}
        other -> Map.take(other, keys)
      end
    end
  end

  def specialized(tag_values, [k1, k2, k3] = keys) do
    fn metadata ->
      case tag_values.(metadata) do
        %{^k1 => v1, ^k2 => v2, ^k3 => v3} -> %{k1 => v1, k2 => v2, k3 => v3}
        other -> Map.take(other, keys)
      end
    end
  end

  def specialized(tag_values, keys) do
    fn metadata -> Map.take(tag_values.(metadata), keys) end
  end
end

identity = & &1

# Realistic: metadata carries more keys than any one metric tags on.
metadata = %{
  tag_a: "exchange_1",
  tag_b: "channel_2",
  tag_c: "region_3",
  request_id: "abc123",
  method: :get,
  status: 200
}

missing = Map.delete(metadata, :tag_b)

n = String.to_integer(System.get_env("N", "3000000"))
reps = String.to_integer(System.get_env("REPS", "7"))

baseline = Loop.best_of(fn -> :ok end, n, reps)

cases =
  for {label, keys} <- [{"1 key", [:tag_a]}, {"2 keys", [:tag_a, :tag_b]}, {"3 keys", [:tag_a, :tag_b, :tag_c]}] do
    cur = TagFns.current(identity, keys)
    spec = TagFns.specialized(identity, keys)

    # Correctness first: the specialized fn must agree with Map.take in both
    # the all-present and missing-key cases.
    ^keys = keys
    true = cur.(metadata) == spec.(metadata)
    true = cur.(missing) == spec.(missing)

    cur_ns = Loop.best_of(fn -> cur.(metadata) end, n, reps) - baseline
    spec_ns = Loop.best_of(fn -> spec.(metadata) end, n, reps) - baseline
    miss_ns = Loop.best_of(fn -> spec.(missing) end, n, reps) - baseline

    {label, cur_ns, spec_ns, miss_ns}
  end

IO.puts("n = #{n}, best of #{reps}, ns per tag-map construction\n")

IO.puts(
  String.pad_trailing("tags", 10) <>
    String.pad_leading("Map.take", 12) <>
    String.pad_leading("specialized", 14) <>
    String.pad_leading("saving", 10) <>
    String.pad_leading("spec, key missing", 20)
)

for {label, cur_ns, spec_ns, miss_ns} <- cases do
  IO.puts(
    String.pad_trailing(label, 10) <>
      String.pad_leading(:erlang.float_to_binary(cur_ns, decimals: 1), 12) <>
      String.pad_leading(:erlang.float_to_binary(spec_ns, decimals: 1), 14) <>
      String.pad_leading(:erlang.float_to_binary(cur_ns - spec_ns, decimals: 1), 10) <>
      String.pad_leading(:erlang.float_to_binary(miss_ns, decimals: 1), 20)
  )
end

IO.puts("\nall specialized/current outputs matched, present and missing-key cases")
