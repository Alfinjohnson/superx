defmodule Orchestrator.Task.Store do
  @moduledoc """
  Task persistence and management.

  Delegates to the appropriate adapter based on persistence mode:
  - `:postgres` → PostgreSQL with Ecto
  - `:memory` → ETS-backed in-memory store

  ## Task Structure

  Tasks follow the A2A protocol structure:

      %{
        "id" => "task-123",
        "status" => %{"state" => "working"},
        "artifacts" => [...],
        "history" => [...],
        "metadata" => %{...}
      }

  ## State Transitions

  Tasks transition through states: `submitted` → `working` → `completed|failed|canceled`
  Once in a terminal state, tasks cannot be updated.
  """

  alias Orchestrator.Persistence

  @doc "Store or update a task."
  @spec put(map()) :: :ok | {:error, term()}
  def put(task), do: adapter().put(task)

  @doc "Get a task by ID."
  @spec get(String.t()) :: map() | nil
  def get(task_id), do: adapter().get(task_id)

  @doc "Delete a task by ID."
  @spec delete(String.t()) :: :ok
  def delete(task_id), do: adapter().delete(task_id)

  @doc """
  Subscribe to updates for a task.

  Returns the current task if it exists, nil otherwise.
  Subscribes the caller to receive {:task_update, task} messages.
  """
  @spec subscribe(String.t()) :: map() | nil
  def subscribe(task_id), do: adapter().subscribe(task_id)

  @doc "List tasks with optional filters."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []), do: adapter().list(opts)

  @doc "Apply a status update to a task."
  @spec apply_status_update(map()) :: :ok | {:error, term()}
  def apply_status_update(update), do: adapter().apply_status_update(update)

  @doc "Apply an artifact update to a task."
  @spec apply_artifact_update(map()) :: :ok | {:error, term()}
  def apply_artifact_update(update), do: adapter().apply_artifact_update(update)

  # Get the appropriate adapter based on persistence mode
  defp adapter, do: Persistence.task_adapter()
end

# Backward compatibility - delegate to new modules
defmodule Orchestrator.TaskStore do
  @moduledoc false

  # No longer needs start_link - stores are started in application.ex
  def put_task(task), do: Orchestrator.Task.Store.put(task)
  def get_task(id), do: Orchestrator.Task.Store.get(id)

  def subscribe(task_id), do: Orchestrator.Task.Store.subscribe(task_id)

  def set_push_config(task_id, params), do: Orchestrator.Task.PushConfig.set(task_id, params)
  def get_push_config(task_id, config_id), do: Orchestrator.Task.PushConfig.get(task_id, config_id)
  def list_push_configs(task_id), do: Orchestrator.Task.PushConfig.list(task_id)
  def delete_push_config(task_id, config_id), do: Orchestrator.Task.PushConfig.delete(task_id, config_id)

  def apply_status_update(update), do: Orchestrator.Task.Store.apply_status_update(update)
  def apply_artifact_update(update), do: Orchestrator.Task.Store.apply_artifact_update(update)
end
