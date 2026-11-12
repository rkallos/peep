defmodule Peep.MixProject do
  use Mix.Project

  @version "5.1.0"

  def project do
    [
      app: :peep,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: [],
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [
        ~r"test/integration/"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/shared"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      # testing, docs, & linting
      {:bandit, "~> 1.6", only: [:test]},
      {:benchee, "~> 1.5", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:inch_ex, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
      {:plug_cowboy, "~> 2.7", only: [:test]},

      # Optional dependencies
      {:plug, "~> 1.16", optional: true}
    ]
  end

  defp docs do
    [
      main: "Peep",
      canonical: "http://hexdocs.pm/peep",
      source_url: "https://github.com/rkallos/peep",
      source_ref: "v#{@version}",
      extras: ["CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        Storage: [~r/Peep.Storage/],
        Bucketing: [~r/Peep.Buckets/]
      ]
    ]
  end

  defp description do
    """
    Provides an opinionated Telemetry.Metrics reporter that supports StatsD and Prometheus.
    """
  end

  defp package do
    [
      maintainers: ["Richard Kallos", "Fabien Lamarche-Filion"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/rkallos/peep",
        "Changelog" => "https://hexdocs.pm/peep/changelog.html"
      },
      files: ~w(lib test/shared LICENSE mix.exs README.md CHANGELOG.md)
    ]
  end
end
