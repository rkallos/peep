defmodule PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test
  import Telemetry.Metrics

  describe "init/1" do
    test "should raise an error if peep_worker is not provided" do
      assert_raise KeyError, ~r/^key :peep_worker not found.*/, fn ->
        Peep.Plug.init([])
      end
    end

    test "should use the default path and unmatched path behaviour if none are provided" do
      assert Peep.Plug.init(peep_worker: :my_peep) == %{
               metrics_path: "/metrics",
               peep_worker: :my_peep,
               on_unmatched_path: :continue
             }
    end

    test "should return a map of all the settings if all are provided" do
      assert Peep.Plug.init(peep_worker: :my_peep, path: "/my-metrics", on_unmatched_path: :halt) ==
               %{metrics_path: "/my-metrics", peep_worker: :my_peep, on_unmatched_path: :halt}
    end
  end

  describe "call/2" do
    test "returns 503 if the metrics worker has not started" do
      check(
        worker?: false,
        path: "/metrics",
        exp_status: 503,
        exp_content_type: "text/plain; charset=utf-8",
        exp_body: "Service Unavailable",
        exp_halted: true
      )
    end

    test "returns metrics if the worker is running at the default path" do
      check(
        path: "/metrics",
        exp_status: 200,
        exp_content_type: "text/plain; charset=utf-8",
        exp_body:
          "# HELP plug_test_counter a counter\n# TYPE plug_test_counter counter\nplug_test_counter 1\n# EOF\n",
        exp_halted: true
      )
    end

    test "returns metrics if the worker is running at a custom path" do
      check(
        plug_opts: [path: "/my-metrics"],
        path: "/my-metrics",
        exp_status: 200,
        exp_content_type: "text/plain; charset=utf-8",
        exp_body:
          "# HELP plug_test_counter a counter\n# TYPE plug_test_counter counter\nplug_test_counter 1\n# EOF\n",
        exp_halted: true
      )
    end

    test "returns 400 for non-GET requests at metrics path" do
      for method <- [:post, :put, :delete, :patch] do
        check(
          method: method,
          path: "/metrics",
          exp_status: 400,
          exp_content_type: "text/plain; charset=utf-8",
          exp_body: "Invalid Request",
          exp_halted: true
        )
      end
    end

    test "returns 404 for non-metrics paths" do
      check(
        plug_opts: [on_unmatched_path: :halt],
        path: "/not-metrics",
        exp_status: 404,
        exp_content_type: "text/plain; charset=utf-8",
        exp_body: "Not Found",
        exp_halted: true
      )
    end

    test "does not halt for non-metrics paths by default" do
      check(path: "/not-metrics", exp_halted: false)
    end
  end

  describe "servers" do
    test "Bandit" do
      name = :bandit_peep
      metrics = [last_value("vm.memory.total", unit: :byte)]
      _peep = start_supervised!({Peep, name: name, metrics: metrics})
      plug = {Peep.Plug, peep_worker: name}

      bandit = start_supervised!({Bandit, plug: plug, port: 0, startup_log: false})
      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

      assert {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, _headers, ~c"# EOF\n"}} =
               :httpc.request("http://localhost:#{port}/metrics")
    end

    test "Plug.Cowboy" do
      name = :cowboy_peep
      metrics = [last_value("vm.memory.total", unit: :byte)]
      _peep = start_supervised!({Peep, name: name, metrics: metrics})
      plug = {Peep.Plug, peep_worker: name}

      start_supervised!({Plug.Cowboy, scheme: :http, plug: plug, options: [port: 0, ref: name]})

      port = :ranch.get_port(name)

      assert {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, _headers, ~c"# EOF\n"}} =
               :httpc.request("http://localhost:#{port}/metrics")
    end
  end

  defp check(opts) do
    name = Peep.Test.fresh_id()

    if Keyword.get(opts, :worker?, true) do
      event = [name]

      start_supervised!(
        {Peep,
         name: name,
         metrics: [counter("plug.test.counter", event_name: event, description: "a counter")]}
      )

      :telemetry.execute(event, %{})
    end

    plug_opts = Peep.Plug.init([peep_worker: name] ++ Keyword.get(opts, :plug_opts, []))
    conn = conn(Keyword.get(opts, :method, :get), Keyword.fetch!(opts, :path))
    conn = Peep.Plug.call(conn, plug_opts)

    assert {conn.status, get_resp_header(conn, "content-type"), conn.resp_body, conn.halted} ==
             {opts[:exp_status], List.wrap(opts[:exp_content_type]), opts[:exp_body],
              Keyword.fetch!(opts, :exp_halted)}
  end
end
