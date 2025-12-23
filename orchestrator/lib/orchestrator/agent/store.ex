defmodule Orchestrator.Agent.Store do
  @moduledoc """
  Agent configuration store.

  Delegates to the appropriate adapter based on persistence mode:
  - `:postgres` → PostgreSQL with Ecto
  - `:memory` → ETS-backed in-memory store

  Agents are bootstrapped from multiple sources on startup (in postgres mode):
  1. Database (persisted agents)
  2. YAML file (`agents.yml`)
  3. Application config (`:orchestrator, :agents`)

  ## Public API

  - `fetch/1` - Get agent by ID
  - `list/0` - List all agents
  - `upsert/1` - Create or update agent
  - `delete/1` - Remove agent
  - `refresh_card/1` - Fetch and cache agent card

  ## Agent Structure

      %{
        "id" => "my-agent",
        "url" => "http://localhost:8000",
        "bearer" => "optional-token",
        "metadata" => %{
          "agentCard" => %{...},
          "protocol" => "a2a",
          "protocolVersion" => "0.3.0"
        }
      }
  """

  alias Orchestrator.Persistence

  @doc "Fetch agent by ID. Returns nil if not found."
  @spec fetch(String.t()) :: map() | nil
  def fetch(agent_id), do: adapter().get(agent_id)

  @doc "List all registered agents."
  @spec list() :: [map()]
  def list, do: adapter().list()

  @doc "Create or update an agent. Agent must have 'id' and 'url' fields."
  @spec upsert(map()) :: {:ok, map()} | {:error, :invalid}
  def upsert(%{"id" => id, "url" => url} = agent) do
    opts = %{
      "bearer" => Map.get(agent, "bearer"),
      "metadata" => Map.get(agent, "metadata", %{})
    }
    adapter().put(id, url, opts)
    {:ok, agent}
  end

  def upsert(%{id: id, url: url} = agent) do
    upsert(%{
      "id" => to_string(id),
      "url" => to_string(url),
      "bearer" => Map.get(agent, :bearer),
      "metadata" => Map.get(agent, :metadata, %{})
    })
  end

  def upsert(_), do: {:error, :invalid}

  @doc "Delete agent by ID."
  @spec delete(String.t()) :: :ok
  def delete(agent_id), do: adapter().delete(agent_id)

  @doc "Refresh agent card from remote URL."
  @spec refresh_card(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_card(agent_id) do
    case Persistence.mode() do
      :postgres -> Orchestrator.Agent.Store.Postgres.refresh_card(agent_id)
      :memory -> {:error, :not_implemented}
    end
  end

  @doc """
  Load agents from application config (for testing/debugging).

  Returns a map of agent_id => agent_data.
  """
  @spec debug_load_agents() :: %{String.t() => map()}
  def debug_load_agents do
    Application.get_env(:orchestrator, :agents, %{})
    |> Enum.map(fn {id, config} ->
      agent = Map.put(config, "id", to_string(id))
      {to_string(id), agent}
    end)
    |> Map.new()
  end

  # Get the appropriate adapter based on persistence mode
  defp adapter, do: Persistence.agent_adapter()
end

# Backward compatibility alias
defmodule Orchestrator.AgentRegistry do
  @moduledoc false
  defdelegate fetch(id), to: Orchestrator.Agent.Store
  defdelegate list(), to: Orchestrator.Agent.Store
  defdelegate upsert(agent), to: Orchestrator.Agent.Store
  defdelegate delete(id), to: Orchestrator.Agent.Store
  defdelegate refresh_card(id), to: Orchestrator.Agent.Store
end
