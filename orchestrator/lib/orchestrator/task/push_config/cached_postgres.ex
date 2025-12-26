defmodule Orchestrator.Task.PushConfig.CachedPostgres do
  @moduledoc """
  Hybrid push config store combining ETS cache with PostgreSQL durability.

  ## Write-Through Cache Pattern
  - All writes go to both PostgreSQL (durable) and ETS (fast reads)
  - Reads primarily from ETS cache (sub-millisecond)
  - Falls back to PostgreSQL if cache miss

  ## Performance Characteristics
  - Reads: ~0.5ms (ETS cache hit)
  - Writes: ~5ms (PostgreSQL + ETS update)
  """

  use GenServer

  import Ecto.Query

  alias Orchestrator.Repo
  alias Orchestrator.Schema.PushConfig, as: PushConfigSchema

  @table :superx_push_configs_cache

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a push notification config for a task.

  Write-through: writes to PostgreSQL first, then updates cache.
  """
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(task_id, config) when is_binary(task_id) and is_map(config) do
    GenServer.call(__MODULE__, {:put, task_id, config})
  end

  @doc """
  Get all push configs for a task.

  Reads from cache first.
  """
  @spec get_for_task(String.t()) :: [map()]
  def get_for_task(task_id) when is_binary(task_id) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, config} -> config["taskId"] == task_id end)
    |> Enum.map(fn {_id, config} -> config end)
  end

  @doc """
  Get a push config by ID.

  Reads from cache first. On cache miss, reads from PostgreSQL
  and populates cache.
  """
  @spec get(String.t()) :: map() | nil
  def get(id) do
    # Validate UUID format before querying
    with {:ok, _uuid} <- Ecto.UUID.cast(id) do
      case :ets.lookup(@table, id) do
        [{^id, config}] ->
          # Cache hit
          config

        [] ->
          # Cache miss - read from database and populate cache
          case Repo.get(PushConfigSchema, id) do
            nil ->
              nil

            config_schema ->
              config = PushConfigSchema.to_map(config_schema)
              :ets.insert(@table, {id, config})
              config
          end
      end
    else
      :error -> nil
    end
  end

  @doc "Delete a push config by ID from both cache and database."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc "Delete all push configs for a task from both cache and database."
  @spec delete_for_task(String.t()) :: :ok
  def delete_for_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:delete_for_task, task_id})
  end

  @doc "List all push configs from cache."
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, config} -> config end)
  end

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Warm cache only when not using SQL sandbox (avoids checkout failures in tests)
    warm_cache_if_allowed()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, task_id, config}, _from, state) do
    attrs = PushConfigSchema.from_map(Map.put(config, "task_id", task_id))

    # Write to PostgreSQL first (durability)
    result =
      %PushConfigSchema{}
      |> PushConfigSchema.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, config_schema} ->
        # Update cache after successful database write
        config_map = PushConfigSchema.to_map(config_schema)
        :ets.insert(@table, {config_map["id"], config_map})
        {:reply, :ok, state}

      {:error, changeset} ->
        {:reply, {:error, format_errors(changeset)}, state}
    end
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    # Delete from database first (ignore invalid IDs to keep API idempotent)
    with {:ok, _uuid} <- Ecto.UUID.cast(id) do
      case Repo.get(PushConfigSchema, id) do
        nil -> :ok
        config -> Repo.delete(config)
      end
    else
      :error -> :ok
    end

    # Remove from cache
    :ets.delete(@table, id)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_for_task, task_id}, _from, state) do
    # Delete from database first
    from(p in PushConfigSchema, where: p.task_id == ^task_id)
    |> Repo.delete_all()

    # Remove from cache
    get_for_task(task_id)
    |> Enum.each(fn config -> :ets.delete(@table, config["id"]) end)

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
    PushConfigSchema
    |> Repo.all()
    |> Enum.each(fn config_schema ->
      config = PushConfigSchema.to_map(config_schema)
      :ets.insert(@table, {config["id"], config})
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
