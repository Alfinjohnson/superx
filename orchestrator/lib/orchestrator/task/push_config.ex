defmodule Orchestrator.Task.PushConfig do
  @moduledoc """
  Push notification configuration management for tasks.

  Delegates to the appropriate adapter based on persistence mode:
  - `:postgres` → PostgreSQL with Ecto
  - `:memory` → ETS-backed in-memory store
  """

  alias Orchestrator.Persistence

  @doc """
  Set push notification config for a task.
  Returns :ok.
  """
  @spec set(String.t(), map()) :: :ok
  def set(task_id, params) when is_binary(task_id) and is_map(params) do
    adapter().put(task_id, params)
  end

  @doc """
  Get a specific push config by config_id.
  """
  @spec get(String.t(), String.t()) :: map() | nil
  def get(_task_id, config_id), do: adapter().get(config_id)

  @doc """
  List all push configs for a task.
  """
  @spec list(String.t()) :: [map()]
  def list(task_id), do: adapter().get_for_task(task_id)

  @doc """
  Delete a push config by task_id and config_id.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(_task_id, config_id), do: adapter().delete(config_id)

  @doc """
  Deliver a push event to all configs for a task.
  Uses Task.Supervisor to spawn async deliveries.
  """
  @spec deliver_event(String.t(), map()) :: :ok
  def deliver_event(task_id, stream_payload) do
    configs = adapter().get_for_task(task_id)

    push_notifier =
      Application.get_env(:orchestrator, :push_notifier, Orchestrator.Infra.PushNotifier)

    Enum.each(configs, fn cfg ->
      Task.Supervisor.start_child(Orchestrator.TaskSupervisor, fn ->
        push_notifier.deliver(stream_payload, cfg)
      end)
    end)

    :ok
  end

  # Get the appropriate adapter based on persistence mode
  defp adapter, do: Persistence.push_config_adapter()
end
