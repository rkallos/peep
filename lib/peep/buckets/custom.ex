defmodule Peep.Buckets.Custom do
  @moduledoc """
  A helper module for writing modules that implement the `Peep.Buckets`
  behavior, with custom bucket boundaries.

  For an example, look at the source of `Peep.Buckets.PowersOfTen`.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [buckets: Keyword.fetch!(opts, :buckets)] do
      @behaviour Peep.Buckets

      require Peep.Buckets.Custom

      buckets = :lists.usort(buckets)
      len = length(buckets)

      unless Enum.all?(buckets, &is_number/1) do
        raise ArgumentError, "expected buckets to be a list of numbers, got: #{buckets}"
      end

      @impl true
      def config(_), do: %{}

      @impl true
      def number_of_buckets(_), do: unquote(len)

      @impl true

      int_buckets =
        buckets
        |> Enum.map(&ceil/1)
        |> Enum.with_index()
        |> Enum.dedup_by(&elem(&1, 0))

      float_buckets =
        buckets
        |> Enum.map(&(&1 * 1.0))
        |> Enum.with_index()

      if len <= 16 do
        # For small bucket length it seems that the linear search is faster than
        # binary search
        for {top, idx} <- int_buckets do
          def bucket_for(val, _) when is_integer(val) and val < unquote(top), do: unquote(idx)
        end

        for {top, idx} <- float_buckets do
          def bucket_for(val, _) when is_float(val) and val < unquote(top), do: unquote(idx)
        end

        def bucket_for(_, _), do: unquote(len)
      else
        # For larger lists binary search still wins
        def bucket_for(val, _) when is_integer(val) do
          Peep.Buckets.Custom.build_tree(unquote(int_buckets), unquote(len), val)
        end

        def bucket_for(val, _) when is_float(val) do
          Peep.Buckets.Custom.build_tree(unquote(float_buckets), unquote(len), val)
        end
      end

      @impl true
      def upper_bound(_, _)

      for {boundary, bucket_idx} <- Enum.with_index(buckets) do
        def upper_bound(unquote(bucket_idx), _), do: unquote(to_string(boundary * 1.0))
      end

      def upper_bound(_, _), do: "+Inf"
    end
  end

  ## Bucket binary search

  @doc false
  defmacro build_tree(buckets, overflow, var) do
    build_bucket_tree(buckets, length(buckets), overflow, var)
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
end
