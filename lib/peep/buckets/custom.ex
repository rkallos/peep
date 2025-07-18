defmodule Peep.Buckets.Custom do
  @moduledoc """
  A helper module for writing modules that implement the `Peep.Buckets`
  behavior, with custom bucket boundaries.

  For an example, look at the source of `Peep.Buckets.PowersOfTen`.
  """

  defmacro __using__(buckets: buckets) do
    quote do
      @buckets :lists.usort(unquote(buckets))

      unless Enum.all?(@buckets, &is_number/1) do
        raise ArgumentError, "expected buckets to be a list of numbers, got: #{@buckets}"
      end

      @behaviour Peep.Buckets

      @impl true
      def config(_), do: %{}

      @impl true
      def number_of_buckets(_), do: length(@buckets)

      @impl true
      def bucket_for(x, _) when is_integer(x) do
        buckets = @buckets
        int_buckets = int_buckets(buckets, nil, 0)

        build_bucket_tree(int_buckets, length(int_buckets), length(buckets), x)
      end

      def bucket_for(x, _) when is_float(x) do
        buckets = @buckets

        float_buckets =
          buckets
          |> Enum.map(&(&1 * 1.0))
          |> Enum.with_index()

        build_bucket_tree(float_buckets, length(float_buckets), length(buckets), x)
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

      defp build_bucket_tree([{bound, lval}], 1, _rval, x) when x < bound, do: lval
      defp build_bucket_tree([{bound, _lval}], 1, rval, _x), do: rval

      defp build_bucket_tree([{lbound, lval}, {_rbound, _mval}], 2, rval, x) when x < lbound,
        do: lval

      defp build_bucket_tree([{_lbound, _lval}, {rbound, mval}], 2, _rval, x) when x < rbound,
        do: mval

      defp build_bucket_tree([{_lbound, _lval}, {_rbound, _mval}], 2, rval, _x), do: rval

      defp build_bucket_tree(bounds, length, rval, x) do
        llength = div(length, 2)
        rlength = length - llength - 1

        {lbounds, rbounds} = Enum.split(bounds, llength)
        [{bound, lval} | rbounds] = rbounds

        case x < bound do
          true -> build_bucket_tree(lbounds, llength, lval, x)
          false -> build_bucket_tree(rbounds, rlength, rval, x)
        end
      end

      @impl true
      for {boundary, bucket_idx} <- Enum.with_index(@buckets) do
        @boundary boundary
        @bucket_idx bucket_idx

        def upper_bound(@bucket_idx, _), do: to_string(@boundary * 1.0)
      end

      def upper_bound(_, _), do: "+Inf"
    end
  end
end
