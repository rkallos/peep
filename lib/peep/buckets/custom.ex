defmodule Peep.Buckets.Custom do
  @moduledoc """
  A helper module for writing modules that implement the `Peep.Buckets`
  behavior, with custom bucket boundaries.

  For an example, look at the source of `Peep.Buckets.PowersOfTen`.
  """

  defmacro __using__(opts) do
    Module.put_attribute(__CALLER__.module, :buckets, Keyword.fetch!(opts, :buckets))

    quote do
      @buckets :lists.usort(unquote(Module.get_attribute(__CALLER__.module, :buckets)))

      unless Enum.all?(@buckets, &is_number/1) do
        raise ArgumentError, "expected buckets to be a list of numbers, got: #{@buckets}"
      end

      @number_of_buckets length(@buckets)

      @behaviour Peep.Buckets

      @impl true
      def config(_), do: %{}

      @impl true
      def number_of_buckets(_), do: @number_of_buckets

      @int_buckets unquote(__MODULE__).int_buckets(@buckets, nil, 1)
      @float_buckets Enum.with_index(Enum.map(@buckets, &(&1 * 1.0)), 1)

      @int_bucket_tree unquote(__MODULE__).build_bucket_tree(@int_buckets, length(@int_buckets))
      @float_bucket_tree unquote(__MODULE__).build_bucket_tree(
                           @float_buckets,
                           length(@float_buckets)
                         )

      @impl true
      def bucket_for(x, _) when is_integer(x) do
        lookup_in_tree(@int_bucket_tree, x, @number_of_buckets)
      end

      def bucket_for(x, _) when is_float(x) do
        lookup_in_tree(@float_bucket_tree, x, @number_of_buckets)
      end

      defp lookup_in_tree(nil, _key, rval), do: rval

      defp lookup_in_tree({_left, {mid, bucket}, _right}, key, _rval) when key == mid,
        do: bucket

      defp lookup_in_tree({left, {mid, bucket}, right}, key, rval) do
        cond do
          key > mid -> lookup_in_tree(right, key, rval)
          key < mid -> lookup_in_tree(left, key, bucket - 1)
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

  @doc false
  def int_buckets([], _prev, _counter) do
    []
  end

  def int_buckets([curr | tail], prev, counter) do
    case ceil(curr) do
      ^prev -> int_buckets(tail, prev, counter + 1)
      curr -> [{curr, counter} | int_buckets(tail, curr, counter + 1)]
    end
  end

  @doc false
  def build_bucket_tree([], 0), do: nil
  def build_bucket_tree([bound], 1), do: {nil, bound, nil}

  def build_bucket_tree([a | b], 2) do
    {nil, a, build_bucket_tree(b, 1)}
  end

  def build_bucket_tree(bounds, length) do
    llength = div(length, 2)
    rlength = length - llength - 1
    {left, right} = Enum.split(bounds, llength)
    {[mid], right} = Enum.split(right, 1)

    {build_bucket_tree(left, llength), mid, build_bucket_tree(right, rlength)}
  end
end
