defmodule Orchestrator.Infra.Cluster do
  @moduledoc """
  Cluster status and load balancing utilities.

  Leverages Elixir's distributed capabilities for horizontal scaling.
  Provides node discovery, health checks, and intelligent request routing.

  ## Configuration

  Uses the `:orchestrator, :cluster` config:

      config :orchestrator, :cluster,
        rpc_timeout: 5_000,
        in_flight_timeout: 1_000

  Or via environment variables:
  - CLUSTER_RPC_TIMEOUT - Timeout for RPC calls to other nodes (default: 5000ms)
  - CLUSTER_IN_FLIGHT_TIMEOUT - Timeout for in-flight queries (default: 1000ms)

  ## Usage

      # Get cluster status
      Orchestrator.Infra.Cluster.status()
      #=> %{node: :node1@host, nodes: [:node1@host, :node2@host], node_count: 2, local_workers: 5}

      # Find best node for an agent
      Orchestrator.Infra.Cluster.best_node_for("agent-123")
      #=> :node2@host
  """

  alias Orchestrator.Agent.Supervisor, as: AgentSupervisor
  alias Orchestrator.Agent.Worker, as: AgentWorker

  # Config access with fallback defaults
  defp cluster_config, do: Application.get_env(:orchestrator, :cluster, [])
  defp rpc_timeout, do: Keyword.get(cluster_config(), :rpc_timeout, 5_000)
  defp in_flight_timeout, do: Keyword.get(cluster_config(), :in_flight_timeout, 1_000)

  @doc "Get cluster status including all connected nodes."
  @spec status() :: map()
  def status do
    %{
      node: node(),
      nodes: [node() | Node.list()],
      node_count: 1 + length(Node.list()),
      local_workers: AgentSupervisor.local_worker_count()
    }
  end

  @doc "Get load information across all nodes."
  @spec load_info() :: [map()]
  def load_info do
    nodes = [node() | Node.list()]

    Enum.map(nodes, fn n ->
      worker_count =
        if n == node() do
          AgentSupervisor.local_worker_count()
        else
          case :rpc.call(n, AgentSupervisor, :local_worker_count, [], rpc_timeout()) do
            {:badrpc, _} -> :unavailable
            count -> count
          end
        end

      %{node: n, workers: worker_count}
    end)
  end

  @doc "Check if we're running in cluster mode."
  @spec clustered?() :: boolean()
  def clustered? do
    Node.list() != []
  end

  @doc """
  Find the best node to handle a request for an agent.
  Returns the node with lowest load for that agent.

  Uses in-flight request counts to distribute load evenly.
  """
  @spec best_node_for(String.t()) :: node()
  def best_node_for(agent_id) do
    nodes = [node() | Node.list()]

    if length(nodes) == 1 do
      node()
    else
      loads =
        Enum.map(nodes, fn n ->
          in_flight = get_agent_load(n, agent_id)
          {n, in_flight}
        end)
        |> Enum.filter(fn {_, load} -> load != :unavailable end)

      case loads do
        [] -> node()
        loads -> {best, _} = Enum.min_by(loads, fn {_, load} -> load end); best
      end
    end
  end

  @doc "Check if a node is reachable."
  @spec node_alive?(node()) :: boolean()
  def node_alive?(n) when n == node(), do: true
  def node_alive?(n), do: n in Node.list()

  # ---- Internal ----

  defp get_agent_load(n, agent_id) when n == node() do
    AgentWorker.in_flight(agent_id)
  end

  defp get_agent_load(n, agent_id) do
    case :rpc.call(n, AgentWorker, :in_flight, [agent_id], in_flight_timeout()) do
      {:badrpc, _} -> :unavailable
      count -> count
    end
  end
end

# Backward compatibility alias
defmodule Orchestrator.Cluster do
  @moduledoc false
  defdelegate status(), to: Orchestrator.Infra.Cluster
  defdelegate load_info(), to: Orchestrator.Infra.Cluster
  defdelegate clustered?(), to: Orchestrator.Infra.Cluster
  defdelegate best_node_for(agent_id), to: Orchestrator.Infra.Cluster
end
