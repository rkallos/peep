defmodule Peep.Test.UDP do
  @moduledoc false

  # The reporter makes the calls, so it finds the results a test queued with
  # fail/2 through its $ancestors. Anything not queued goes to :gen_udp.

  def fail(fun, results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    Process.put({__MODULE__, fun}, agent)
    :ok
  end

  def open(port, opts) do
    next_result(:open) || :gen_udp.open(port, opts)
  end

  def send(socket, host, port, data) do
    next_result(:send) || :gen_udp.send(socket, host, port, data)
  end

  defp next_result(fun) do
    case Enum.find_value(Process.get(:"$ancestors", []), &queue(&1, fun)) do
      nil -> nil
      agent -> Agent.get_and_update(agent, &pop/1)
    end
  end

  defp queue(pid, fun) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        List.keyfind(dictionary, {__MODULE__, fun}, 0, {nil, nil}) |> elem(1)

      nil ->
        nil
    end
  end

  defp queue(_name, _fun), do: nil

  defp pop([result | rest]), do: {result, rest}
  defp pop([]), do: {nil, []}
end
