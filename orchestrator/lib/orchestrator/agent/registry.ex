defmodule Orchestrator.Agent.Registry do
  @moduledoc """
  Distributed process registry for agent workers.

  Uses Horde.Registry for cluster-wide process lookup.
  Workers register themselves using `{:agent_worker, agent_id}` keys.

  ## Usage

      # Lookup a worker
      case Horde.Registry.lookup(Agent.Registry, {:agent_worker, "my-agent"}) do
        [{pid, _}] -> {:ok, pid}
        [] -> :not_found
      end
  """

  use Horde.Registry

  def start_link(_opts) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Horde.Registry.init(
      Keyword.merge(opts,
        keys: :unique,
        members: :auto
      )
    )
  end

  @doc "Lookup a worker by agent ID."
  @spec lookup_worker(String.t()) :: {:ok, pid()} | :error
  def lookup_worker(agent_id) do
    case Horde.Registry.lookup(__MODULE__, {:agent_worker, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "List all registered agent IDs."
  @spec list_agent_ids() :: [String.t()]
  def list_agent_ids do
    Horde.Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn {:agent_worker, id} -> id end)
  end
end

# Backward compatibility - old name still works
defmodule Orchestrator.AgentRegistry.Distributed do
  @moduledoc false
  # Just delegate lookups to new registry
  def lookup(key) do
    Horde.Registry.lookup(Orchestrator.Agent.Registry, key)
  end
end
