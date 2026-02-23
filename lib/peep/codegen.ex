defmodule Peep.Codegen do
  @moduledoc false

  alias Peep.Options
  alias Peep.Persistent

  def module(peep_name) do
    :"Peep.Codegen.#{peep_name}"
  end

  def create(%Options{} = peep_options) do
    %Options{name: name, global_tags: global_tags} = peep_options

    module_name = module(name)
    handle_event_ast = build_handle_event_ast(name)
    other_funs_ast = other_funs_ast()

    module_ast =
      quote do
        defmodule unquote(module_name) do
          require Persistent

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
        global_tags = global_tags()

        %Persistent{
          events_to_metrics: %{^event => metrics},
          storage: {storage_mod, storage}
        } = Persistent.fast_fetch(unquote(peep_name))

        insert_metrics(metrics, storage_mod, storage, global_tags, measurements, metadata)
      end

      defp insert_metrics([], _, _, _, _, _), do: :ok

      defp insert_metrics(
             [{metric, id} | metrics],
             storage_mod,
             storage,
             global_tags,
             measurements,
             metadata
           ) do
        %{measurement: measurement, keep: keep} = metric

        if keep?(keep, metadata, measurement) do
          case fetch_measurement(measurement, measurements, metadata) do
            value when is_number(value) ->
              %{tags: tags, tag_values: tag_values} = metric
              tag_values = tag_values.(metadata)
              tags = Map.merge(global_tags, Map.take(tag_values, tags))
              storage_mod.insert_metric(storage, id, metric, value, tags)

            _ ->
              nil
          end
        end

        insert_metrics(metrics, storage_mod, storage, global_tags, measurements, metadata)
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp other_funs_ast() do
    quote do
      defp keep?(keep, metadata, measurement) when is_function(keep, 2) do
        keep.(metadata, measurement)
      end

      defp keep?(keep, metadata, _measurement) when is_function(keep, 1) do
        keep.(metadata)
      end

      defp keep?(_keep, _metadata, _measurement), do: true

      defp fetch_measurement(%Telemetry.Metrics.Counter{}, _measurements, _metadata) do
        1
      end

      defp fetch_measurement(nil, _, _), do: nil

      defp fetch_measurement(fun, measurements, _) when is_function(fun, 1) do
        fun.(measurements)
      end

      defp fetch_measurement(fun, measurements, metadata) when is_function(fun, 2) do
        fun.(measurements, metadata)
      end

      defp fetch_measurement(key, measurements, _) do
        case measurements do
          %{^key => value} -> value
          _ -> 1
        end
      end
    end
  end
end
