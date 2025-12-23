defmodule Orchestrator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Orchestrator.Persistence

  @impl true
  def start(_type, _args) do
    children =
      [
        # Cluster formation (optional - disabled by default)
        {Cluster.Supervisor, [cluster_topologies(), [name: Orchestrator.ClusterSupervisor]]},

        # Core services
        {Finch, name: Orchestrator.Finch, pools: finch_pools()},
        {Task.Supervisor, name: Orchestrator.TaskSupervisor},

        # Distributed registry & supervisor (works single-node and clustered)
        {Horde.Registry, [name: Orchestrator.Agent.Registry, keys: :unique, members: :auto]},
        {Orchestrator.Agent.Supervisor, []},

        # PubSub for task notifications
        Orchestrator.Task.PubSub,

        # HTTP server
        {Plug.Cowboy, scheme: :http, plug: Orchestrator.Router, options: [port: port()]}
      ]
      |> prepend_persistence_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Load agents from config sources after supervisor starts
    case result do
      {:ok, _pid} ->
        Orchestrator.Agent.Loader.load_all()

      _ ->
        :ok
    end

    result
  end

  # Add persistence-specific children based on mode
  defp prepend_persistence_children(children) do
    persistence_children =
      case Persistence.mode() do
        :postgres ->
          # PostgreSQL mode: start Repo (ETS stores not needed)
          [Orchestrator.Repo]

        :memory ->
          # Memory mode: start ETS-backed stores
          [
            Orchestrator.Task.Store.Memory,
            Orchestrator.Agent.Store.Memory,
            Orchestrator.Task.PushConfig.Memory
          ]
      end

    persistence_children ++ children
  end

  defp port do
    Application.get_env(:orchestrator, :port, nil) ||
      (System.get_env("PORT", "4000") |> String.to_integer())
  end

  defp cluster_topologies do
    # Configure via env var: CLUSTER_STRATEGY=gossip|dns|kubernetes
    case System.get_env("CLUSTER_STRATEGY") do
      "gossip" ->
        [
          orchestrator: [
            strategy: Cluster.Strategy.Gossip,
            config: [port: String.to_integer(System.get_env("CLUSTER_PORT", "45892"))]
          ]
        ]

      "dns" ->
        polling_interval = Application.get_env(:orchestrator, :cluster, [])
          |> Keyword.get(:dns_polling_interval, 5_000)

        [
          orchestrator: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: polling_interval,
              query: System.get_env("CLUSTER_DNS_QUERY", "orchestrator.local"),
              node_basename: System.get_env("CLUSTER_NODE_BASENAME", "orchestrator")
            ]
          ]
        ]

      "kubernetes" ->
        [
          orchestrator: [
            strategy: Elixir.Cluster.Strategy.Kubernetes,
            config: [
              mode: :dns,
              kubernetes_node_basename: System.get_env("CLUSTER_NODE_BASENAME", "orchestrator"),
              kubernetes_selector: System.get_env("CLUSTER_K8S_SELECTOR", "app=orchestrator"),
              kubernetes_namespace: System.get_env("CLUSTER_K8S_NAMESPACE", "default")
            ]
          ]
        ]

      _ ->
        # No clustering - single node mode
        []
    end
  end

  defp finch_pools do
    # Read pool settings from config
    http_config = Application.get_env(:orchestrator, :http, [])
    pool_size = Keyword.get(http_config, :pool_size, 50)

    # Split pool_size across 4 pools for better parallelism
    # Each pool has size/4 connections (min 10)
    per_pool = max(10, div(pool_size, 4))

    %{
      :default => [size: per_pool, count: 4]
    }
  end
end
