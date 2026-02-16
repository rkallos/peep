defmodule Peep.Codegen do
  @moduledoc false

  alias Peep.Options

  def module(peep_name) do
    :"Peep.Codegen.#{peep_name}"
  end

  def create(%Options{} = peep_options) do
    %Options{name: name, global_tags: global_tags} = peep_options

    module_name = module(name)
    handle_event_ast = build_handle_event_ast(name)
    other_funs_ast = other_funs_ast(global_tags)

    module_ast =
      quote do
        defmodule unquote(module_name) do
          import Peep.Persistent, only: [fast_fetch: 1, persistent: 1]

          @compile {:inline, global_tags: 0}

          def global_tags(), do: unquote(Macro.escape(global_tags))
          def name(), do: unquote(name)

          unquote(handle_event_ast)
          unquote(other_funs_ast)
        end
      end

    [{_module, _bin}] = Code.compile_quoted(module_ast)
    :ok
  end

  def purge(peep_name) do
    :code.purge(module(peep_name))
  end

  defp build_handle_event_ast(peep_name) do
    quote do
      def handle_event(event, measurements, metadata, _) do
        persistent(
          events_to_metrics: %{^event => metrics},
          storage: {storage_mod, storage}
        ) = fast_fetch(unquote(peep_name))

        store_metrics(metrics, measurements, metadata, storage_mod, storage)
      end

      defp store_metrics([], _measurements, _metadata, _mod, _data), do: :ok

      defp store_metrics([{metric, id} | rest], measurements, metadata, mod, data) do
        %{
          measurement: measurement,
          tag_values: tag_values,
          tags: tags,
          keep: keep
        } = metric

        if keep?(keep, metadata, measurement) do
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case fetch_measurement(measurement, measurements, metadata) do
            value when is_number(value) ->
              mod.insert_metric(
                data,
                id,
                metric,
                value,
                meta(metadata, tag_values, tags)
              )

            _ ->
              nil
          end
        end

        store_metrics(rest, measurements, metadata, mod, data)
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp other_funs_ast(global_tags) do
    quote do
      defp keep?(keep, metadata, measurement) when is_function(keep, 2),
        do: keep.(metadata, measurement)

      defp keep?(keep, metadata, _measurement) when is_function(keep, 1), do: keep.(metadata)
      defp keep?(_keep, _metadata, _measurement), do: true

      # When tags are empty, just return global tags
      defp meta(tags, _map, _keys) when tags == %{}, do: global_tags()
      # When selected list is empty, just return global tags
      defp meta(_tags, _map, []), do: global_tags()

      # Try to avoid calling `Map.merge/2` if not needed
      if unquote(global_tags == %{}) do
        defp meta(meta, _map, tags) when is_function(tags, 1), do: tags.(meta)
        defp meta(tags, map, keys), do: Map.take(map.(tags), keys)
      else
        defp meta(meta, _map, tags) when is_function(tags, 1), do: Map.merge(global_tags(), tags.(meta))
        defp meta(tags, map, keys), do: Map.merge(global_tags(), Map.take(map.(tags), keys))
      end

      defp fetch_measurement(%Telemetry.Metrics.Counter{}, _measurements, _metadata) do
        1
      end

      defp fetch_measurement(measurement, measurements, metadata) do
        case measurement do
          nil ->
            nil

          fun when is_function(fun, 1) ->
            fun.(measurements)

          fun when is_function(fun, 2) ->
            fun.(measurements, metadata)

          key ->
            case measurements do
              %{^key => value} -> value
              _ -> 1
            end
        end
      end
    end
  end
end
