defmodule Orchestrator.Agent.Supervisor do
  @moduledoc """
  Distributed DynamicSupervisor for per-agent workers.

  Uses Horde for automatic distribution across cluster nodes.
  Workers are automatically rebalanced when nodes join/leave.

  ## Distribution

  - Workers are spread across cluster using uniform distribution
  - Automatic rebalancing on node join/leave
  - Lookup via distributed Horde.Registry

  ## Usage

      # Start worker for an agent (cluster-aware)
      {:ok, pid} = Agent.Supervisor.start_worker(agent)

      # Count local workers
      count = Agent.Supervisor.local_worker_count()
  """

  use Horde.DynamicSupervisor

  alias Orchestrator.Agent.Worker

  def start_link(_opts) do
    Horde.DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Horde.DynamicSupervisor.init(
      strategy: :one_for_one,
      members: :auto,
      distribution_strategy: Horde.UniformDistribution
    )
  end

  @doc """
  Start a worker for an agent.

  Distributed across cluster - checks if worker exists anywhere first.
  Returns existing pid if already started.
  """
  @spec start_worker(map()) :: {:ok, pid()} | {:error, term()}
  def start_worker(agent) do
    agent_id = agent["id"]

    # Check if worker already exists in cluster
    case Horde.Registry.lookup(Orchestrator.Agent.Registry, {:agent_worker, agent_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Worker, agent}

        case Horde.DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @doc "Terminate a worker by agent ID."
  @spec terminate_worker(String.t()) :: :ok | {:error, :not_found}
  def terminate_worker(agent_id) do
    case Horde.Registry.lookup(Orchestrator.Agent.Registry, {:agent_worker, agent_id}) do
      [{pid, _}] ->
        Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Get count of workers on this node."
  @spec local_worker_count() :: non_neg_integer()
  def local_worker_count do
    Horde.DynamicSupervisor.count_children(__MODULE__)[:workers] || 0
  end

  @doc "List all worker pids across the cluster."
  @spec list_workers() :: [pid()]
  def list_workers do
    Horde.DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

# Backward compatibility alias
defmodule Orchestrator.AgentSupervisor do
  @moduledoc false
  defdelegate start_link(opts), to: Orchestrator.Agent.Supervisor
  defdelegate start_worker(agent), to: Orchestrator.Agent.Supervisor
  defdelegate local_worker_count(), to: Orchestrator.Agent.Supervisor
end
