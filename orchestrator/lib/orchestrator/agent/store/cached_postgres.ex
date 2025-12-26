defmodule Orchestrator.Agent.Store.CachedPostgres do
  @moduledoc """
  Hybrid agent store combining ETS cache with PostgreSQL durability.

  ## Write-Through Cache Pattern
  - All writes go to both PostgreSQL (durable) and ETS (fast reads)
  - Reads primarily from ETS cache (sub-millisecond)
  - Falls back to PostgreSQL if cache miss
  - On cache miss, populates cache for subsequent reads

  ## Performance Characteristics
  - Reads: ~0.5ms (ETS cache hit)
  - Writes: ~5ms (PostgreSQL + ETS update)
  - Cache miss reads: ~5ms (PostgreSQL + cache populate)

  ## Best For
  - Production deployments with many agent lookups
  - Agent registries that rarely change but are frequently queried
  """

  use GenServer

  alias Orchestrator.Repo
  alias Orchestrator.Schema.Agent, as: AgentSchema

  @table :superx_agents_cache

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register or update an agent.

  Write-through: writes to PostgreSQL first, then updates cache.
  """
  @spec put(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(agent_id, url, opts \\ %{}) when is_binary(agent_id) and is_binary(url) do
    GenServer.call(__MODULE__, {:put, agent_id, url, opts})
  end

  @doc """
  Get an agent by ID.

  Reads from cache first. On cache miss, reads from PostgreSQL
  and populates cache.
  """
  @spec get(String.t()) :: map() | nil
  def get(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent}] ->
        # Cache hit
        agent

      [] ->
        # Cache miss - read from database and populate cache
        case Repo.get(AgentSchema, agent_id) do
          nil ->
            nil

          agent_schema ->
            agent = AgentSchema.to_map(agent_schema)
            :ets.insert(@table, {agent_id, agent})
            agent
        end
    end
  end

  @doc "Delete an agent by ID from both cache and database."
  @spec delete(String.t()) :: :ok
  def delete(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:delete, agent_id})
  end

  @doc """
  List all registered agents.

  Reads from cache for fast iteration.
  """
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, agent} -> agent end)
  end

  @doc "Find agents by URL prefix."
  @spec find_by_url(String.t()) :: [map()]
  def find_by_url(url_prefix) when is_binary(url_prefix) do
    list()
    |> Enum.filter(fn agent ->
      String.starts_with?(agent["url"] || "", url_prefix)
    end)
  end

  @doc "Find agents by metadata key-value."
  @spec find_by_metadata(String.t(), term()) :: [map()]
  def find_by_metadata(key, value) when is_binary(key) do
    list()
    |> Enum.filter(fn agent ->
      get_in(agent, ["metadata", key]) == value
    end)
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Warm up cache only when not using SQL sandbox (avoids checkout failures in tests)
    warm_cache_if_allowed()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, agent_id, url, opts}, _from, state) do
    attrs = %{
      id: agent_id,
      url: url,
      bearer: Map.get(opts, "bearer") || Map.get(opts, :bearer),
      protocol: Map.get(opts, "protocol") || Map.get(opts, :protocol, "a2a"),
      metadata: Map.get(opts, "metadata") || Map.get(opts, :metadata, %{})
    }

    # Write to PostgreSQL first (durability)
    result =
      case Repo.get(AgentSchema, agent_id) do
        nil ->
          %AgentSchema{}
          |> AgentSchema.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> AgentSchema.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, agent_schema} ->
        # Update cache after successful database write
        agent = AgentSchema.to_map(agent_schema)
        :ets.insert(@table, {agent_id, agent})
        {:reply, {:ok, agent}, state}

      {:error, changeset} ->
        {:reply, {:error, format_errors(changeset)}, state}
    end
  end

  @impl true
  def handle_call({:delete, agent_id}, _from, state) do
    # Delete from database first
    case Repo.get(AgentSchema, agent_id) do
      nil -> :ok
      agent -> Repo.delete(agent)
    end

    # Remove from cache
    :ets.delete(@table, agent_id)

    {:reply, :ok, state}
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp warm_cache_if_allowed do
    repo_config = Application.get_env(:orchestrator, Orchestrator.Repo, [])

    # Skip warmup in test/sandbox to avoid sandbox checkout errors during init
    if Keyword.get(repo_config, :pool) != Ecto.Adapters.SQL.Sandbox do
      warm_cache()
    end
  end

  defp warm_cache do
    AgentSchema
    |> Repo.all()
    |> Enum.each(fn agent_schema ->
      agent = AgentSchema.to_map(agent_schema)
      :ets.insert(@table, {agent["id"], agent})
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
