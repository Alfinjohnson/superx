defmodule Orchestrator.Task.Store.CachedPostgres do
  @moduledoc """
  Hybrid task store combining ETS cache with PostgreSQL durability.

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
  - Production deployments needing both durability and speed
  - High read:write ratio workloads
  - Distributed systems requiring node crash recovery

  ## Trade-offs
  - Higher memory usage (cache + database)
  - Cache consistency handled via process-local ETS (no distributed cache)
  - Each node has its own cache (eventual consistency across cluster)
  """

  use GenServer

  import Ecto.Query

  alias Orchestrator.Repo
  alias Orchestrator.Schema.Task, as: TaskSchema
  alias Orchestrator.Task.PubSub, as: TaskPubSub
  alias Orchestrator.Task.PushConfig

  @table :superx_tasks_cache

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store or update a task.

  Write-through: writes to PostgreSQL first, then updates cache.
  """
  @spec put(map()) :: :ok | {:error, term()}
  def put(task) when is_map(task) do
    GenServer.call(__MODULE__, {:put, task})
  end

  @doc """
  Get a task by ID.

  Reads from cache first. On cache miss, reads from PostgreSQL
  and populates cache.
  """
  @spec get(String.t()) :: map() | nil
  def get(task_id) when is_binary(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] ->
        # Cache hit
        task

      [] ->
        # Cache miss - read from database and populate cache
        case Repo.get(TaskSchema, task_id) do
          nil ->
            nil

          task_schema ->
            task = TaskSchema.to_map(task_schema)
            :ets.insert(@table, {task_id, task})
            task
        end
    end
  end

  @doc "Delete a task by ID from both cache and database."
  @spec delete(String.t()) :: :ok
  def delete(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:delete, task_id})
  end

  @doc """
  Subscribe to updates for a task.

  Returns the current task if it exists, nil otherwise.
  """
  @spec subscribe(String.t()) :: map() | nil
  def subscribe(task_id) when is_binary(task_id) do
    case get(task_id) do
      nil ->
        nil

      task ->
        TaskPubSub.subscribe(task_id)
        task
    end
  end

  @doc """
  List tasks with optional filters.

  Reads from database (not cached) to ensure consistency
  for list operations.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query = from(t in TaskSchema, order_by: [desc: t.inserted_at], limit: ^limit)

    query =
      if agent_id = Keyword.get(opts, :agent_id) do
        from(t in query, where: t.agent_id == ^agent_id)
      else
        query
      end

    query =
      if context_id = Keyword.get(opts, :context_id) do
        from(t in query, where: t.context_id == ^context_id)
      else
        query
      end

    query =
      if status = Keyword.get(opts, :status) do
        from(t in query, where: fragment("?->>'state' = ?", t.status, ^status))
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(&TaskSchema.to_map/1)
  end

  @doc "Apply a status update to a task."
  @spec apply_status_update(map()) :: :ok | {:error, term()}
  def apply_status_update(%{"taskId" => task_id} = update) do
    case get(task_id) do
      nil ->
        {:error, :not_found}

      task ->
        status = Map.get(update, "status", %{})
        merged = Map.put(task, "status", status)

        case put(merged) do
          :ok ->
            TaskPubSub.broadcast(task_id, {:status_update, merged})
            PushConfig.deliver_event(task_id, %{"statusUpdate" => update})
            :ok

          error ->
            error
        end
    end
  end

  def apply_status_update(_), do: {:error, :invalid}

  @doc "Apply an artifact update to a task."
  @spec apply_artifact_update(map()) :: :ok | {:error, term()}
  def apply_artifact_update(%{"taskId" => task_id, "artifact" => artifact}) do
    case get(task_id) do
      nil ->
        {:error, :not_found}

      task ->
        artifacts = Map.get(task, "artifacts", []) ++ [artifact]
        merged = Map.put(task, "artifacts", artifacts)

        case put(merged) do
          :ok ->
            TaskPubSub.broadcast(task_id, {:artifact_update, merged})
            PushConfig.deliver_event(task_id, %{"artifactUpdate" => %{"taskId" => task_id, "artifact" => artifact}})
            :ok

          error ->
            error
        end
    end
  end

  def apply_artifact_update(_), do: {:error, :invalid}

  # -------------------------------------------------------------------
  # Server Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, task}, _from, state) do
    # Validate task has id
    case task do
      %{"id" => nil} ->
        {:reply, {:error, :invalid_task}, state}

      %{"id" => ""} ->
        {:reply, {:error, :invalid_task}, state}

      %{"id" => task_id} when is_binary(task_id) ->
        # Check if existing task is in terminal state before updating
        existing = get(task_id)

        if existing && terminal?(existing) do
          {:reply, {:error, :terminal}, state}
        else
          attrs = TaskSchema.from_map(task)

          # Write to PostgreSQL first (durability)
          result =
            case Repo.get(TaskSchema, attrs.id) do
              nil ->
                %TaskSchema{}
                |> TaskSchema.changeset(attrs)
                |> Repo.insert()

              existing_schema ->
                existing_schema
                |> TaskSchema.changeset(attrs)
                |> Repo.update()
            end

          case result do
            {:ok, _} ->
              # Update cache after successful database write
              :ets.insert(@table, {task_id, task})
              # Broadcast task update to subscribers (for SSE streams)
              TaskPubSub.broadcast(task_id, {:task_update, task})
              {:reply, :ok, state}

            {:error, changeset} ->
              {:reply, {:error, format_errors(changeset)}, state}
          end
        end

      _ ->
        {:reply, {:error, :invalid_task}, state}
    end
  end

  @impl true
  def handle_call({:delete, task_id}, _from, state) do
    # Delete from database first
    case Repo.get(TaskSchema, task_id) do
      nil -> :ok
      task -> Repo.delete(task)
    end

    # Remove from cache
    :ets.delete(@table, task_id)

    {:reply, :ok, state}
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @terminal_states ~w(completed failed canceled)

  defp terminal?(%{"status" => %{"state" => state}}) when state in @terminal_states, do: true
  defp terminal?(_), do: false
end
