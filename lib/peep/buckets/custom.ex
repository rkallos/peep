defmodule Peep.Buckets.Custom do
  @moduledoc """
  A helper module for writing modules that implement the `Peep.Buckets`
  behavior, with custom bucket boundaries.

  For an example, look at the source of `Peep.Buckets.PowersOfTen`.
  """

  defmacro __using__(opts) do
    buckets =
      Keyword.fetch!(opts, :buckets)
      |> :lists.usort()

    unless Enum.all?(buckets, &is_number/1) do
      raise ArgumentError, "expected buckets to be a list of numbers, got: #{buckets}"
    end

    number_of_buckets = length(buckets)

    quote do
      @behaviour Peep.Buckets

      @impl true
      def config(_), do: %{}

      @impl true
      def number_of_buckets(_), do: unquote(number_of_buckets)

      @impl true
      unquote(bucket_for_ast(buckets))

      @impl true
      unquote(upper_bound_ast(buckets))
    end
  end

  ## Bucket binary search

  defp bucket_for_ast(buckets) do
    int_buckets = int_buckets(buckets, nil, 0)

    float_buckets =
      buckets
      |> Enum.map(&(&1 * 1.0))
      |> Enum.with_index()

    variable = Macro.var(:x, nil)

    int_length = length(int_buckets)
    int_tree = build_bucket_tree(int_buckets, int_length, length(buckets), variable)

    float_length = length(float_buckets)
    float_tree = build_bucket_tree(float_buckets, float_length, length(buckets), variable)

    quote do
      def bucket_for(unquote(variable), _) when is_integer(unquote(variable)) do
        unquote(int_tree)
      end

      def bucket_for(unquote(variable), _) when is_float(unquote(variable)) do
        unquote(float_tree)
      end
    end

    # |> tap(&IO.puts(Code.format_string!(Macro.to_string(&1))))
  end

  defp build_bucket_tree([{bound, lval}], 1, rval, variable) do
    quote do
      case unquote(variable) do
        x when x < unquote(bound) ->
          unquote(lval)

        _ ->
          unquote(rval)
      end
    end
  end

  defp build_bucket_tree([{lbound, lval}, {rbound, mval}], 2, rval, variable) do
    quote do
      case unquote(variable) do
        x when x < unquote(lbound) ->
          unquote(lval)

        x when x < unquote(rbound) ->
          unquote(mval)

        _ ->
          unquote(rval)
      end
    end
  end

  defp build_bucket_tree(bounds, length, rval, variable) do
    llength = div(length, 2)
    rlength = length - llength - 1

    {lbounds, rbounds} = Enum.split(bounds, llength)
    [{bound, lval} | rbounds] = rbounds

    quote do
      case unquote(variable) do
        x when x < unquote(bound) ->
          unquote(build_bucket_tree(lbounds, llength, lval, variable))

        _ ->
          unquote(build_bucket_tree(rbounds, rlength, rval, variable))
      end
    end
  end

  defp int_buckets([], _prev, _counter) do
    []
  end

  defp int_buckets([curr | tail], prev, counter) do
    case ceil(curr) do
      ^prev -> int_buckets(tail, prev, counter + 1)
      curr -> [{curr, counter} | int_buckets(tail, curr, counter + 1)]
    end
  end

  ## Upper bound

  defp upper_bound_ast(buckets) do
    bucket_defns =
      for {boundary, bucket_idx} <- Enum.with_index(buckets) do
        quote do
          def upper_bound(unquote(bucket_idx), _), do: unquote(int_to_float_string(boundary))
        end
      end

    final_defn =
      quote do
        def upper_bound(_, _), do: "+Inf"
      end

    bucket_defns ++ [final_defn]
  end

  defp int_to_float_string(int) do
    to_string(int * 1.0)
  end
end
