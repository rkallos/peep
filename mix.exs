defmodule Peep.MixProject do
  use Mix.Project

  def project do
    [
      app: :peep,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      compile: ["format", "compile"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_options, "~> 1.0"},
      {:telemetry_metrics, "~> 0.6"},

      # linting
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2",
       [
         only: [:dev, :test],
         runtime: false
       ]},
      {:inch_ex, "~> 2.0", only: [:dev, :test], runtime: false},

      # testing
      {:nimble_parsec, "~> 1.3", only: [:test]}
    ]
  end
end
