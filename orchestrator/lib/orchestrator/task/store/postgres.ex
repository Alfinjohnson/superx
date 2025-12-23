defmodule Orchestrator.Task.Store.Postgres do
  @moduledoc """
  PostgreSQL task store using Ecto.

  This adapter stores tasks in PostgreSQL for persistence across restarts
  and horizontal scaling with shared database.
  """

  import Ecto.Query, only: [from: 2]

  alias Orchestrator.Repo
  alias Orchestrator.Schema.Task, as: TaskSchema
  alias Orchestrator.Utils
  alias Orchestrator.Task.PubSub, as: TaskPubSub
  alias Orchestrator.Task.PushConfig

  @doc "Store or update a task."
  @spec put(map()) :: :ok | {:error, term()}
  def put(%{"id" => id} = task) when is_binary(id) do
    case ensure_not_terminal(id) do
      :ok ->
        upsert_task(task)
        TaskPubSub.broadcast(id, {:task_update, task})
        PushConfig.deliver_event(id, %{"task" => task})
        :ok

      {:error, _} = error ->
        error
    end
  end

  def put(_), do: {:error, :invalid_task}

  @doc "Get a task by ID."
  @spec get(String.t()) :: map() | nil
  def get(task_id) do
    case Repo.get(TaskSchema, task_id) do
      nil -> nil
      %TaskSchema{payload: payload} -> payload
    end
  end

  @doc "Delete a task by ID."
  @spec delete(String.t()) :: :ok
  def delete(task_id) do
    Repo.delete_all(from(t in TaskSchema, where: t.id == ^task_id))
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

    TaskSchema
    |> Ecto.Query.limit(^limit)
    |> Ecto.Query.order_by([t], desc: t.inserted_at)
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
  # Private Helpers
  # -------------------------------------------------------------------

  defp ensure_not_terminal(id) do
    case Repo.get(TaskSchema, id) do
      %TaskSchema{payload: %{"status" => %{"state" => prev_state}}} ->
        if Utils.terminal_state?(prev_state) do
          {:error, :terminal}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp upsert_task(task) do
    changeset = TaskSchema.changeset(%TaskSchema{}, %{id: task["id"], payload: task})

    Repo.insert(changeset,
      on_conflict: [set: [payload: task, updated_at: NaiveDateTime.utc_now()]],
      conflict_target: :id
    )
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

  defp find_artifact_index(artifacts, %{"artifactId" => id}) do
    Enum.find_index(artifacts, fn a -> a["artifactId"] == id end)
  end

  defp find_artifact_index(artifacts, %{"id" => id}) do
    Enum.find_index(artifacts, fn a -> (a["artifactId"] || a["id"]) == id end)
  end

  defp find_artifact_index(artifacts, %{"name" => name}) do
    Enum.find_index(artifacts, fn a -> a["name"] == name end)
  end

  defp find_artifact_index(_, _), do: nil
end
