defmodule Orchestrator.Web.Handlers.Message do
  @moduledoc """
  Handles message.send and message.stream JSON-RPC methods.

  Responsible for routing messages to agents via the AgentWorker
  and returning responses or initiating streaming.
  """

  require Logger

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PushConfig
  alias Orchestrator.Web.RpcErrors
  alias Orchestrator.Web.Response

  @stream_init_timeout 5_000

  @doc "Handle message.send - synchronous message sending to an agent."
  @spec handle_send(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  def handle_send(conn, id, params) do
    with {:ok, agent_id} <- fetch_agent_id(params),
         {:ok, _agent} <- fetch_agent(agent_id),
         env = build_envelope("send", params, id, agent_id),
         {:ok, forwarded} <- AgentWorker.call(agent_id, env) do
      store_task_with_webhook(forwarded, env.webhook)
      Response.send_success(conn, id, forwarded)
    else
      error -> RpcErrors.handle_error(conn, id, error)
    end
  end

  @doc "Handle message.stream - streaming message sending to an agent."
  @spec handle_stream(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  def handle_stream(conn, id, params) do
    with {:ok, agent_id} <- fetch_agent_id(params),
         {:ok, _agent} <- fetch_agent(agent_id),
         env = build_envelope("stream", params, id, agent_id),
         {:ok, _streaming} <- AgentWorker.stream(agent_id, env, self()) do
      handle_stream_init(conn, id, env)
    else
      error -> RpcErrors.handle_error(conn, id, error)
    end
  end

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp fetch_agent_id(%{"agentId" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_agent_id(_), do: {:error, :no_agent}

  defp fetch_agent(agent_id) do
    case AgentStore.fetch(agent_id) do
      nil -> {:error, :agent_missing}
      agent -> {:ok, agent}
    end
  end

  defp build_envelope(method, params, rpc_id, agent_id) do
    Envelope.new(%{
      method: method,
      task_id: Map.get(params, "taskId"),
      context_id: Map.get(params, "contextId"),
      message: Map.get(params, "message"),
      payload: params,
      agent_id: agent_id,
      rpc_id: rpc_id,
      webhook: get_in(params, ["metadata", "webhook"])
    })
  end

  # Wait for stream initialization and handle result
  defp handle_stream_init(conn, id, env) do
    receive do
      {:stream_init, ^id, result} ->
        store_task_with_webhook(result, env.webhook)
        Response.send_success(conn, id, result)

      {:stream_error, ^id, status} ->
        RpcErrors.send_error(
          conn,
          id,
          RpcErrors.code(:remote_error),
          "Remote stream error #{status}"
        )
    after
      @stream_init_timeout ->
        RpcErrors.send_error(
          conn,
          id,
          RpcErrors.code(:timeout),
          "Stream initialization timed out"
        )
    end
  end

  # Store task and optionally deliver per-request webhook
  defp store_task_with_webhook(%{"id" => task_id} = task, per_request_webhook) do
    case TaskStore.put(task) do
      :ok -> :ok
      {:error, :terminal} -> Logger.info("task already terminal; skipped store")
      {:error, _} -> Logger.warning("failed to store task")
    end

    if per_request_webhook do
      PushConfig.deliver_event(task_id, %{"task" => task}, per_request_webhook)
    end

    :ok
  end

  defp store_task_with_webhook(_, _), do: :ok
end
