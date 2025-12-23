defmodule Orchestrator.Task.Store.Memory do
  @moduledoc """
  In-memory task store using ETS.

  This adapter stores tasks in an ETS table that is lost on restart.
  Ideal for stateless deployments where task persistence is handled externally.
  """

  use GenServer

  alias Orchestrator.Utils
  alias Orchestrator.Task.PubSub, as: TaskPubSub
  alias Orchestrator.Task.PushConfig

  @table :superx_tasks

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store or update a task."
  @spec put(map()) :: :ok | {:error, term()}
  def put(task) when is_map(task) do
    GenServer.call(__MODULE__, {:put, task})
  end

  @doc "Get a task by ID."
  @spec get(String.t()) :: map() | nil
  def get(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> task
      [] -> nil
    end
  end

  @doc "Delete a task by ID."
  @spec delete(String.t()) :: :ok
  def delete(task_id) do
    :ets.delete(@table, task_id)
    :ok
  end

  @doc "Subscribe to updates for a task."
  @spec subscribe(String.t()) :: map() | nil
  def subscribe(task_id) do
    case get(task_id) do
      nil -> nil
      task ->
        TaskPubSub.subscribe(task_id)
        task
    end
  end

  @doc "List tasks with optional filters."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    @table
    |> :ets.tab2list()
    |> Enum.take(limit)
    |> Enum.map(fn {_id, task} -> task end)
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
  def apply_artifact_update(%{"taskId" => task_id} = update) do
    case get(task_id) do
      nil ->
        {:error, :not_found}

      task ->
        artifact = Map.get(update, "artifact") || Map.get(update, "artifacts")
        merged = merge_artifact(task, artifact)

        case put(merged) do
          :ok ->
            TaskPubSub.broadcast(task_id, {:artifact_update, merged})
            PushConfig.deliver_event(task_id, %{"artifactUpdate" => update})
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
  def handle_call({:put, %{"id" => id} = task}, _from, state) when is_binary(id) do
    case ensure_not_terminal(id) do
      :ok ->
        :ets.insert(@table, {id, task})
        TaskPubSub.broadcast(id, {:task_update, task})
        PushConfig.deliver_event(id, %{"task" => task})
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:put, _}, _from, state) do
    {:reply, {:error, :invalid_task}, state}
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp ensure_not_terminal(id) do
    case get(id) do
      %{"status" => %{"state" => prev_state}} ->
        if Utils.terminal_state?(prev_state) do
          {:error, :terminal}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp merge_artifact(task, nil), do: task

  defp merge_artifact(task, artifact) when is_map(artifact) do
    existing = Map.get(task, "artifacts", [])

    case find_artifact_index(existing, artifact) do
      nil -> Map.put(task, "artifacts", existing ++ [artifact])
      idx -> Map.put(task, "artifacts", List.replace_at(existing, idx, artifact))
    end
  end

  defp merge_artifact(task, artifacts) when is_list(artifacts) do
    Enum.reduce(artifacts, task, &merge_artifact(&2, &1))
  end

  defp find_artifact_index(artifacts, %{"name" => name}) do
    Enum.find_index(artifacts, fn a -> a["name"] == name end)
  end

  defp find_artifact_index(_, _), do: nil
end
