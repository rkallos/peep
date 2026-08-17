import Telemetry.Metrics

# Checks that the batched-insert prototypes store the same thing the
# per-metric path does, so the timing numbers are comparing like with like.

alias Peep.Storage.Rustler, as: R

metrics = [
  counter("verify.count", tags: [:t]),
  sum("verify.total", tags: [:t]),
  last_value("verify.gauge", tags: [:t]),
  distribution("verify.dist",
    tags: [:t],
    reporter_options: [max_value: 1_000_000, bucket_variability: 0.3]
  )
]

{:ok, _} = Peep.start_link(name: :verify, metrics: metrics, storage: {Peep.Storage.Rustler, []})

{R, storage} = Peep.Persistent.storage(:verify)
resolved = R.resolve(storage)
persistent = Peep.Persistent.fetch(:verify)
itm = Peep.Persistent.ids_to_metrics(persistent)

per = %{t: "per_metric"}
flat = %{t: "flat"}
tag = %{t: "tagged"}

# Per-metric path: 3 counter hits, sum 10+20+30, gauge ends at 7, dist 3 samples.
for _ <- 1..3, do: R.insert_metric(resolved, 0, elem(itm, 0), 1, per)
for v <- [10, 20, 30], do: R.insert_metric(resolved, 1, elem(itm, 1), v, per)
for v <- [3, 5, 7], do: R.insert_metric(resolved, 2, elem(itm, 2), v, per)
for v <- [100, 200, 300], do: R.insert_metric(resolved, 3, elem(itm, 3), v, per)

# Same totals, driven through insert_metrics_flat.
for _ <- 1..3, do: R.insert_metrics_flat(resolved, [{0, 1, flat}])
R.insert_metrics_flat(resolved, [{1, 10, flat}, {1, 20, flat}, {1, 30, flat}])
for v <- [3, 5, 7], do: R.insert_metrics_flat(resolved, [{2, v, flat}])
R.insert_metrics_flat(resolved, [{3, 100, flat}, {3, 200, flat}, {3, 300, flat}])

# Same totals again, through insert_metrics_tagged. tag_results is a tuple of
# the event's distinct tags maps; the batch carries indices into it.
tag_results = {%{t: "unused"}, tag}
for _ <- 1..3, do: R.insert_metrics_tagged(resolved, tag_results, [{0, 1, 1}])
R.insert_metrics_tagged(resolved, tag_results, [{1, 10, 1}, {1, 20, 1}, {1, 30, 1}])
for v <- [3, 5, 7], do: R.insert_metrics_tagged(resolved, tag_results, [{2, v, 1}])
R.insert_metrics_tagged(resolved, tag_results, [{3, 100, 1}, {3, 200, 1}, {3, 300, 1}])

all = R.get_all_metrics(storage, persistent)

series =
  Map.new(all, fn {metric, tagged_series} ->
    {metric.name, Map.new(tagged_series, fn {%{t: t}, v} -> {t, v} end)}
  end)

failures =
  for {name, expectation} <- [
        {[:verify, :count], nil},
        {[:verify, :total], nil},
        {[:verify, :gauge], nil},
        {[:verify, :dist], nil}
      ],
      reduce: [] do
    acc ->
      _ = expectation
      by_path = Map.fetch!(series, name)
      reference = Map.fetch!(by_path, "per_metric")

      Enum.reduce(["flat", "tagged"], acc, fn variant, acc ->
        actual = Map.fetch!(by_path, variant)

        if actual == reference do
          acc
        else
          [{name, variant, reference, actual} | acc]
        end
      end)
  end

IO.puts("stored series:")

for {name, by_variant} <- Enum.sort(series) do
  IO.puts("  #{Enum.join(name, ".")}")

  for {variant, value} <- Enum.sort(by_variant) do
    IO.puts("    #{String.pad_trailing(variant, 12)} #{inspect(value)}")
  end
end

case failures do
  [] ->
    IO.puts("\nOK: flat and tagged match per_metric for all four metric types")

  failures ->
    IO.puts("\nMISMATCHES:")
    for f <- failures, do: IO.puts("  #{inspect(f)}")
    System.halt(1)
end
