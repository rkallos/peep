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

        :lists.foreach(
          fn {metric, id} ->
            %{
              measurement: measurement,
              tag_values: tag_values,
              tags: tags,
              keep: keep
            } = metric

            if keep?(keep, metadata) do
              case fetch_measurement(measurement, measurements, metadata) do
                value when is_number(value) ->
                  tag_values = tag_values.(metadata)
                  tags = Map.merge(global_tags, Map.take(tag_values, tags))
                  storage_mod.insert_metric(storage, id, metric, value, tags)

                _ ->
                  nil
              end
            end
          end,
          metrics
        )
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp other_funs_ast() do
    quote do
      defp keep?(nil, _metadata), do: true
      defp keep?(keep, metadata), do: keep.(metadata)

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
              %{^key => nil} -> 1
              %{^key => false} -> 1
              %{^key => value} -> value
              _ -> 1
            end
        end
      end
    end
  end
end
