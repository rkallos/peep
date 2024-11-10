defmodule Peep.Plug do
  @moduledoc """
  Use this plug to expose your metrics on an endpoint for scraping. This is useful if you are using Prometheus.

  This plug accepts the following options:

  * `:peep_worker` - The name of the Peep worker to use. This is required.
  * `:path` - The path to expose the metrics on. Defaults to `"/metrics"`.

  ## Usage

  You can use this plug in your Phoenix endpoint like this:

    ```elixir
    plug Peep.Plug, peep_worker: :my_peep_worker
    ```

  Or if you'd rather use a different path:

    ```elixir
    plug Peep.Plug, path: "/my-metrics"
    ```

  If you are not using Phoenix, you can use it directly with Cowboy by adding this to your applications's supervision tree:

    ```elixir
    {Plug.Cowboy, scheme: :http, plug: Peep.Plug, options: [port: 9000]}
    ```

  Similarly, if you are using Bandit, you can use it like so:

    ```elixir
    {Bandit, [
      scheme: :http,
      plug: {Peep.Plug, peep_worker: :my_app},
      port: 9000
    ]}
    ```
  """

  @behaviour Plug

  import Plug.Conn
  alias Plug.Conn
  require Logger

  @default_metrics_path "/metrics"

  @impl Plug
  def init(opts) do
    %{
      metrics_path: Keyword.get(opts, :path, @default_metrics_path),
      peep_worker: Keyword.fetch!(opts, :peep_worker)
    }
  end

  @impl Plug
  def call(%Conn{request_path: metrics_path, method: "GET"} = conn, %{
        metrics_path: metrics_path,
        peep_worker: peep_worker
      }) do
    metrics =
      Peep.get_all_metrics(peep_worker)
      |> Peep.Prometheus.export()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
    |> halt()
  rescue
    error ->
      Logger.error(Exception.format(:error, error, __STACKTRACE__))

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Service Unavailable")
      |> halt()
  end

  def call(%Conn{request_path: metrics_path} = conn, %{metrics_path: metrics_path}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Invalid Request")
    |> halt()
  end

  def call(%Conn{} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
