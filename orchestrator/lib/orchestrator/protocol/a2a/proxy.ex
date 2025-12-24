defmodule Orchestrator.Protocol.A2A.Proxy do
  @moduledoc """
  Handles A2A proxy requests to agents through the orchestrator.

  This module enables the orchestrator to act as a transparent proxy
  for A2A protocol requests, routing them to the appropriate agent
  while handling protocol normalization.
  """

  import Plug.Conn
  require Logger

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Web.RpcErrors
  alias Orchestrator.Web.Handlers.Message, as: MessageHandler

  @doc """
  Handle an A2A proxy request by routing to the appropriate agent.
  """
  @spec handle_request(Plug.Conn.t(), String.t(), any(), String.t(), map()) :: Plug.Conn.t()
  def handle_request(conn, agent_id, rpc_id, wire_method, payload) do
    Logger.debug("A2A proxy request: method=#{wire_method} agent=#{agent_id}")

    case AgentStore.fetch(agent_id) do
      nil ->
        RpcErrors.send_error(conn, rpc_id, RpcErrors.code(:agent_not_found), "Agent not found")

      agent ->
        # Get protocol adapter for this agent (returns module directly)
        adapter = Orchestrator.Protocol.adapter_for_agent(agent)
        # Normalize wire method to canonical method using adapter
        canonical = adapter.normalize_method(wire_method)
        handle_canonical_method(conn, agent_id, agent, adapter, canonical, rpc_id, payload)
    end
  end

  # -------------------------------------------------------------------
  # Canonical Method Routing
  # -------------------------------------------------------------------

  defp handle_canonical_method(conn, agent_id, agent, adapter, canonical, rpc_id, payload) do
    params = Map.get(payload, "params", %{}) |> Map.put("agentId", agent_id)

    case canonical do
      # Core messaging - handle through orchestrator
      :send_message ->
        MessageHandler.handle_send(conn, rpc_id, params)

      :stream_message ->
        MessageHandler.handle_stream(conn, rpc_id, params)

      :subscribe_task ->
        MessageHandler.handle_stream(conn, rpc_id, params)

      # Task management - some handled locally, some forwarded
      :get_task ->
        Orchestrator.Web.Handlers.Task.handle_get(conn, rpc_id, params["taskId"])

      :list_tasks ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      :cancel_task ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      # Push notification methods - forward to agent
      :set_push_config ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      :get_push_config ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      :list_push_configs ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      :delete_push_config ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      # Agent card
      :get_agent_card ->
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)

      # Unknown method - forward to agent
      :unknown ->
        Logger.debug("Unknown method, forwarding to agent #{agent_id}")
        forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload)
    end
  end

  @doc """
  Forward a JSON-RPC request to the remote agent.
  """
  @spec forward_to_agent(Plug.Conn.t(), String.t(), map(), module(), any(), map()) ::
          Plug.Conn.t()
  def forward_to_agent(conn, agent_id, agent, _adapter, rpc_id, payload) do
    url = agent["url"]
    Logger.debug("Forwarding to agent URL: #{url}")

    case Req.post(url, json: payload, finch: Orchestrator.Finch, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"error" => error}}} ->
        # Remote agent returned an error - pass it through
        send_resp(
          conn,
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => rpc_id, "error" => error})
        )

      {:ok, %{status: 200, body: body}} ->
        send_resp(conn, 200, Jason.encode!(body))

      {:ok, %{status: status, body: body}} ->
        send_resp(conn, status, Jason.encode!(body))

      {:error, reason} ->
        Logger.warning("Failed to reach agent #{agent_id}: #{inspect(reason)}")
        RpcErrors.send_error(conn, rpc_id, RpcErrors.code(:remote_error), "Failed to reach agent")
    end
  end
end

# Backward compatibility alias
defmodule Orchestrator.Web.Proxy do
  @moduledoc false
  defdelegate handle_request(conn, agent_id, rpc_id, wire_method, payload), to: Orchestrator.Protocol.A2A.Proxy
  defdelegate forward_to_agent(conn, agent_id, agent, adapter, rpc_id, payload), to: Orchestrator.Protocol.A2A.Proxy
end
