defmodule StatsdSendingTest do
  use ExUnit.Case

  alias Peep.Statsd
  alias Peep.Statsd.Packet
  alias Peep.Support.StorageCounter
  alias Telemetry.Metrics

  test "Packet.send/3 sends data via UDP" do
    # Open a receiving socket
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, recv_port} = :inet.port(recv_socket)

    packet = Packet.new(1472) |> Packet.add(:key, "test.metric:1|c")

    # Open a sending socket
    {:ok, send_socket} = :gen_udp.open(0, active: false)

    statsd_opts = [host: {127, 0, 0, 1}, port: recv_port]

    {packet_size, result} = Packet.send(packet, send_socket, statsd_opts)

    assert result == :ok
    assert packet_size > 0

    {:ok, {_addr, _port, data}} = :gen_udp.recv(recv_socket, 0, 1000)
    assert data =~ "test.metric:1|c"

    :gen_udp.close(recv_socket)
    :gen_udp.close(send_socket)
  end

  test "Packet.send/3 uses port 0 for UDS-style host" do
    # Open a :local socket for UDS-style sending
    sock_path = ~c"/tmp/peep_test_#{System.unique_integer([:positive])}.sock"
    {:ok, send_socket} = :gen_udp.open(0, [:local, active: false])

    packet = Packet.new(1472) |> Packet.add(:key, "test:1|c")
    statsd_opts = [host: {:local, sock_path}]

    {packet_size, result} = Packet.send(packet, send_socket, statsd_opts)

    # The send will fail because the socket file doesn't exist, but we cover
    # the {:local, _} port selection branch
    assert packet_size > 0
    assert {:error, _} = result

    :gen_udp.close(send_socket)
  end

  test "make_and_send_packets sends metrics over UDP" do
    name = StorageCounter.fresh_id()

    # Open a receiving socket
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, recv_port} = :inet.port(recv_socket)

    counter = Metrics.counter("statsd.send.counter")

    opts = [name: name, metrics: [counter]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, counter, 1, %{})

    statsd_opts = [
      host: {127, 0, 0, 1},
      port: recv_port,
      formatter: :standard,
      mtu: 1472
    ]

    state = Statsd.make_state(statsd_opts)
    metrics = Peep.get_all_metrics(name)

    new_state = Statsd.make_and_send_packets(metrics, state)

    # State should be updated with new prev cache
    assert %Statsd{} = new_state

    {:ok, {_addr, _port, data}} = :gen_udp.recv(recv_socket, 0, 1000)
    assert data =~ "statsd.send.counter"

    :gen_udp.close(recv_socket)
  end

  test "make_and_send_packets with float last_value covers n2b float clause" do
    name = StorageCounter.fresh_id()

    {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, recv_port} = :inet.port(recv_socket)

    last_value = Metrics.last_value("statsd.send.gauge")

    opts = [name: name, metrics: [last_value]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, last_value, 3.14, %{})

    statsd_opts = [
      host: {127, 0, 0, 1},
      port: recv_port,
      formatter: :standard,
      mtu: 1472
    ]

    state = Statsd.make_state(statsd_opts)
    metrics = Peep.get_all_metrics(name)

    _new_state = Statsd.make_and_send_packets(metrics, state)

    {:ok, {_addr, _port, data}} = :gen_udp.recv(recv_socket, 0, 1000)
    assert data =~ "statsd.send.gauge:3.14|g"

    :gen_udp.close(recv_socket)
  end

  test "send_packets handles :eagain error gracefully" do
    name = StorageCounter.fresh_id()

    counter = Metrics.counter("statsd.eagain.counter")
    opts = [name: name, metrics: [counter]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, counter, 1, %{})

    # Create a state with a closed socket to trigger errors
    statsd_opts = [
      host: {127, 0, 0, 1},
      port: 1,
      formatter: :standard,
      mtu: 1472
    ]

    state = Statsd.make_state(statsd_opts)
    # Close the socket to force send errors
    :gen_udp.close(state.socket)

    metrics = Peep.get_all_metrics(name)
    # This should not crash, the error branch sets socket to nil
    new_state = Statsd.make_and_send_packets(metrics, state)
    assert new_state.socket == nil
  end

  test "send_packets with closed socket and multiple packets covers nil-socket skip" do
    name = StorageCounter.fresh_id()

    # Create many metrics to produce multiple packets with a small MTU
    metrics_list =
      for i <- 1..10 do
        Metrics.counter("statsd.multi.counter.#{i}")
      end

    opts = [name: name, metrics: metrics_list]
    {:ok, _pid} = Peep.start_link(opts)

    for m <- metrics_list do
      Peep.insert_metric(name, m, 1, %{})
    end

    # Use small MTU to force multiple packets
    statsd_opts = [
      host: {127, 0, 0, 1},
      port: 1,
      formatter: :standard,
      mtu: 50
    ]

    state = Statsd.make_state(statsd_opts)
    # Close the socket - first packet send fails ({:error, _reason} sets socket to nil),
    # subsequent packets hit the nil-socket skip path (L61-62)
    :gen_udp.close(state.socket)

    metrics = Peep.get_all_metrics(name)
    new_state = Statsd.make_and_send_packets(metrics, state)
    assert new_state.socket == nil
  end

  test "try_to_open_socket passthrough when socket already open" do
    # Calling make_and_send_packets twice covers the try_to_open_socket
    # passthrough (L149) on the second call since socket is already open
    name = StorageCounter.fresh_id()

    {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, recv_port} = :inet.port(recv_socket)

    counter = Metrics.counter("statsd.passthrough.counter")
    opts = [name: name, metrics: [counter]]
    {:ok, _pid} = Peep.start_link(opts)

    Peep.insert_metric(name, counter, 1, %{})

    statsd_opts = [
      host: {127, 0, 0, 1},
      port: recv_port,
      formatter: :standard,
      mtu: 1472
    ]

    state = Statsd.make_state(statsd_opts)
    metrics = Peep.get_all_metrics(name)

    # First call opens socket
    state2 = Statsd.make_and_send_packets(metrics, state)
    assert state2.socket != nil

    # Insert another metric
    Peep.insert_metric(name, counter, 1, %{})
    metrics2 = Peep.get_all_metrics(name)

    # Second call reuses existing socket (try_to_open_socket passthrough)
    state3 = Statsd.make_and_send_packets(metrics2, state2)
    assert state3.socket != nil

    :gen_udp.close(recv_socket)
  end
end
