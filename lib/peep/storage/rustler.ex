defmodule Peep.Storage.Rustler do
  use Rustler, otp_app: :peep, crate: "peep_storage_rustler"

  @behaviour Peep.Storage

  @impl true
  def new(_), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def register_metrics(_, _), do: :erlang.error(:nif_not_loaded)

  @impl true
  def storage_size(_), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def insert_metric(_, _, _, _, _), do: :erlang.nif_error(:nif_not_loaded)

  # `persistent` carries the whole `:persistent` record, but the NIF only
  # needs `ids_to_metrics` out of it - extracted here, via the proper
  # accessor, rather than parsed positionally out of the record on the Rust
  # side.
  @impl true
  def get_all_metrics(storage, persistent) do
    storage
    |> nif_get_all_metrics(Peep.Persistent.ids_to_metrics(persistent))
    |> relabel_distribution_buckets()
  end

  def nif_get_all_metrics(_storage, _ids_to_metrics), do: :erlang.nif_error(:nif_not_loaded)

  # The NIF can't call an arbitrary (possibly third-party)
  # `Peep.Buckets` calculator's `upper_bound/2` itself, so a Distribution's
  # bucket map comes back keyed by plain integer index instead of the real
  # `"1.222222"`-style label. This turns those indices into labels, the same
  # way `Peep.Storage.Atomics.values/1` already does for the ETS backend.
  defp relabel_distribution_buckets(metrics) do
    Map.new(metrics, fn
      {%Telemetry.Metrics.Distribution{} = metric, tagged_series} ->
        {mod, config} = Peep.Buckets.config(metric)

        relabeled =
          Map.new(tagged_series, fn {tags, buckets} ->
            {tags, relabel_buckets(buckets, mod, config)}
          end)

        {metric, relabeled}

      pair ->
        pair
    end)
  end

  defp relabel_buckets(buckets, mod, config) do
    Map.new(buckets, fn
      {idx, count} when is_integer(idx) -> {mod.upper_bound(idx, config), count}
      other_pair -> other_pair
    end)
  end

  @impl true
  def prune_tags(_, _), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def resolve(_), do: :erlang.nif_error(:nif_not_loaded)
end
