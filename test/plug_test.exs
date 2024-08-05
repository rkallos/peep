defmodule PlugTest do
  use ExUnit.Case, async: false
  use Plug.Test

  import Telemetry.Metrics

  @peep_worker :my_peep
  @peep_worker_id :my_peep_id

  describe "init/1" do
    test "should raise an error if peep_worker is not provided" do
      assert_raise KeyError, ~r/^key :peep_worker not found.*/, fn ->
        Peep.Plug.init([])
      end
    end

    test "should use the default path is one is not provided" do
      assert %{metrics_path: "/metrics"} = Peep.Plug.init(peep_worker: @peep_worker)
    end

    test "should return a map of all the settings if all are provided" do
      assert %{metrics_path: "/my-metrics", peep_worker: @peep_worker} =
               Peep.Plug.init(peep_worker: @peep_worker, path: "/my-metrics")
    end
  end

  describe "call/2" do
    setup [:setup_peep_worker]

    @tag :capture_log
    test "returns 503 if the metrics worker has not started" do
      stop_supervised!(@peep_worker_id)
      opts = Peep.Plug.init(peep_worker: @peep_worker)
      conn = conn(:get, "/metrics")
      response = Peep.Plug.call(conn, opts)

      assert response.status == 503
      assert response.resp_body == "Service Unavailable"
    end

    test "returns metrics if the worker is running at the default path" do
      opts = Peep.Plug.init(peep_worker: @peep_worker)
      conn = conn(:get, "/metrics")
      response = Peep.Plug.call(conn, opts)

      assert response.status == 200
    end

    test "returns metrics if the worker is running at a custom path" do
      opts = Peep.Plug.init(peep_worker: @peep_worker, path: "/my-metrics")
      conn = conn(:get, "/my-metrics")
      response = Peep.Plug.call(conn, opts)

      assert response.status == 200
    end

    test "returns 400 for non-GET requests at metrics path" do
      opts = Peep.Plug.init(peep_worker: @peep_worker)

      for method <- [:post, :put, :delete, :patch] do
        conn = conn(method, "/metrics")
        response = Peep.Plug.call(conn, opts)

        assert response.status == 400
      end
    end

    test "returns 404 for non-metrics paths" do
      opts = Peep.Plug.init(peep_worker: @peep_worker)
      conn = conn(:get, "/not-metrics")
      response = Peep.Plug.call(conn, opts)

      assert response.status == 404
    end
  end

  def setup_peep_worker(context) do
    start_supervised!(
      {Peep, name: @peep_worker, metrics: [last_value("vm.memory.total", unit: :byte)]},
      id: @peep_worker_id
    )

    context
  end
end
