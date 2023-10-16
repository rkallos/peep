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

  defp bucket_for_ast(buckets) do
    bucket_defns =
      for {boundary, bucket_idx} <- Enum.with_index(buckets) do
        quote do
          def bucket_for(n, _) when n < unquote(boundary), do: unquote(bucket_idx)
        end
      end

    final_defn =
      quote do
        def bucket_for(_, _), do: unquote(length(buckets))
      end

    bucket_defns ++ [final_defn]
  end

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
    # kind of a hack, but nothing else came to mind
    to_string(:math.pow(int, 1))
  end
end
