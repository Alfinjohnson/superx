defmodule Orchestrator.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/superx/orchestrator"

  def project do
    [
      app: :orchestrator,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls],

      # Hex.pm metadata
      name: "SuperX Orchestrator",
      description: "Agentic Gateway Orchestrator for A2A protocol",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Orchestrator.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"},
      {:finch, "~> 0.18"},
      {:yaml_elixir, "~> 2.11"},
      {:telemetry, "~> 1.2"},
      # Clustering & Distribution
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.9"},
      # Testing
      {:mox, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    # Tests run in memory mode by default (no DB needed)
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end

  defp releases do
    [
      orchestrator: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end

  defp package do
    [
      name: "superx_orchestrator",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib priv config mix.exs README.md LICENSE CHANGELOG.md agents.yml)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
