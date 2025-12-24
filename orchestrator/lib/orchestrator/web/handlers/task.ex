defmodule Orchestrator.Web.Handlers.Task do
  @moduledoc """
  Handles tasks.* JSON-RPC methods.

  Provides task retrieval, subscription (SSE streaming),
  and push notification configuration management.
  """

  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PushConfig
  alias Orchestrator.Web.RpcErrors
  alias Orchestrator.Web.Response
  alias Orchestrator.Web.Streaming

  @doc """
  Handle tasks.get - returns a task by ID.
  """
  @spec handle_get(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_get(conn, id, task_id) do
    case TaskStore.get(task_id) do
      nil ->
        RpcErrors.send_error(conn, id, RpcErrors.code(:task_not_found), "Task not found")

      task ->
        Response.send_success(conn, id, task)
    end
  end

  @doc """
  Handle tasks.subscribe - subscribes to task updates via SSE.
  """
  @spec handle_subscribe(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_subscribe(conn, id, task_id) do
    case TaskStore.subscribe(task_id) do
      nil ->
        RpcErrors.send_error(conn, id, RpcErrors.code(:task_not_found), "Task not found")

      task ->
        Streaming.stream_task(conn, id, task)
    end
  end

  @doc """
  Handle tasks.pushNotificationConfig.set - sets push notification config for a task.
  """
  @spec handle_push_config_set(Plug.Conn.t(), any(), String.t(), map()) :: Plug.Conn.t()
  def handle_push_config_set(conn, id, task_id, config) do
    case TaskStore.get(task_id) do
      nil ->
        RpcErrors.send_error(conn, id, RpcErrors.code(:task_not_found), "Task not found")

      _task ->
        case PushConfig.set(task_id, config) do
          {:ok, saved} ->
            Response.send_success(conn, id, saved)

          {:error, :invalid} ->
            RpcErrors.send_error(conn, id, RpcErrors.code(:invalid_params), "Invalid push config")
        end
    end
  end

  @doc """
  Handle tasks.pushNotificationConfig.get - gets a specific push config.
  """
  @spec handle_push_config_get(Plug.Conn.t(), any(), String.t(), String.t()) :: Plug.Conn.t()
  def handle_push_config_get(conn, id, task_id, config_id) do
    case PushConfig.get(task_id, config_id) do
      nil ->
        RpcErrors.send_error(
          conn,
          id,
          RpcErrors.code(:task_not_found),
          "Push notification config not found"
        )

      cfg ->
        Response.send_success(conn, id, cfg)
    end
  end

  @doc """
  Handle tasks.pushNotificationConfig.list - lists all push configs for a task.
  """
  @spec handle_push_config_list(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  def handle_push_config_list(conn, id, task_id) do
    cfgs = PushConfig.list(task_id)
    Response.send_success(conn, id, cfgs)
  end

  @doc """
  Handle tasks.pushNotificationConfig.delete - deletes a push config.
  """
  @spec handle_push_config_delete(Plug.Conn.t(), any(), String.t(), String.t()) :: Plug.Conn.t()
  def handle_push_config_delete(conn, id, task_id, config_id) do
    PushConfig.delete(task_id, config_id)
    Response.send_success(conn, id, true)
  end
end
