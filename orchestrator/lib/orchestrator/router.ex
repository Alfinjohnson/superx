defmodule Orchestrator.Router do
  @moduledoc """
  HTTP router for the orchestrator.

  This is a thin routing layer that:
  - Defines HTTP endpoints (health, cluster, RPC, agent cards, A2A proxy)
  - Dispatches JSON-RPC methods to appropriate handler modules
  - Handles request logging and ID generation

  All business logic is delegated to handler modules:
  - `Web.Handlers.Message` - message.send, message.stream
  - `Web.Handlers.Agent` - agents.* methods
  - `Web.Handlers.Task` - tasks.* methods
  - `Web.AgentCard` - agent card serving
  - `Web.Proxy` - A2A proxy forwarding
  """

  use Plug.Router
  require Logger

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Infra.Cluster
  alias Orchestrator.Utils
  alias Orchestrator.Web.AgentCard
  alias Orchestrator.Web.Handlers.Agent, as: AgentHandler
  alias Orchestrator.Web.Handlers.Message, as: MessageHandler
  alias Orchestrator.Web.Handlers.Task, as: TaskHandler
  alias Orchestrator.Web.Proxy
  alias Orchestrator.Web.RpcErrors

  plug(:request_id)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]
  )

  plug(:match)
  plug(:dispatch)

  # -------------------------------------------------------------------
  # Health & Cluster Endpoints
  # -------------------------------------------------------------------

  get "/health" do
    cluster = Cluster.status()

    resp = %{
      status: "ok",
      mode: "memory",
      node: cluster.node,
      cluster_size: cluster.node_count,
      local_workers: cluster.local_workers
    }

    send_resp(conn, 200, Jason.encode!(resp))
  end

  get "/cluster" do
    resp = %{
      status: Cluster.status(),
      load: Cluster.load_info()
    }

    send_resp(conn, 200, Jason.encode!(resp))
  end

  # -------------------------------------------------------------------
  # JSON-RPC Endpoint
  # -------------------------------------------------------------------

  post "/rpc" do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload ->
        handle_rpc(conn, id, method, Map.get(payload, "params", %{}))

      _ ->
        RpcErrors.send_error(conn, nil, RpcErrors.code(:invalid_request), "Invalid Request")
    end
  end

  # -------------------------------------------------------------------
  # Agent Card Endpoint
  # -------------------------------------------------------------------

  get "/agents/:agent_id/.well-known/agent-card.json" do
    case AgentStore.fetch(agent_id) do
      nil ->
        send_resp(conn, 404, Jason.encode!(%{error: "Agent not found"}))

      agent ->
        AgentCard.serve(conn, agent_id, agent)
    end
  end

  # -------------------------------------------------------------------
  # A2A Proxy Endpoint
  # -------------------------------------------------------------------

  post "/agents/:agent_id" do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload ->
        Proxy.handle_request(conn, agent_id, id, method, payload)

      _ ->
        send_resp(
          conn,
          400,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{code: -32600, message: "Invalid Request"}
          })
        )
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # -------------------------------------------------------------------
  # RPC Method Dispatch
  # -------------------------------------------------------------------

  # Message methods
  defp handle_rpc(conn, id, "message.send", params),
    do: MessageHandler.handle_send(conn, id, params)

  defp handle_rpc(conn, id, "message.stream", params),
    do: MessageHandler.handle_stream(conn, id, params)

  # Agent methods
  defp handle_rpc(conn, id, "agents.list", _params),
    do: AgentHandler.handle_list(conn, id)

  defp handle_rpc(conn, id, "agents.get", %{"id" => agent_id}),
    do: AgentHandler.handle_get(conn, id, agent_id)

  defp handle_rpc(conn, id, "agents.upsert", %{"agent" => agent}),
    do: AgentHandler.handle_upsert(conn, id, agent)

  defp handle_rpc(conn, id, "agents.delete", %{"id" => agent_id}),
    do: AgentHandler.handle_delete(conn, id, agent_id)

  defp handle_rpc(conn, id, "agents.refreshCard", %{"id" => agent_id}),
    do: AgentHandler.handle_refresh_card(conn, id, agent_id)

  defp handle_rpc(conn, id, "agents.health", %{"id" => agent_id}),
    do: AgentHandler.handle_health(conn, id, agent_id)

  defp handle_rpc(conn, id, "agents.health", _params),
    do: AgentHandler.handle_health_all(conn, id)

  # Task methods
  defp handle_rpc(conn, id, "tasks.get", %{"taskId" => task_id}),
    do: TaskHandler.handle_get(conn, id, task_id)

  defp handle_rpc(conn, id, "tasks.subscribe", %{"taskId" => task_id}),
    do: TaskHandler.handle_subscribe(conn, id, task_id)

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.set", %{
         "taskId" => task_id,
         "config" => cfg
       }),
       do: TaskHandler.handle_push_config_set(conn, id, task_id, cfg)

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.get", %{
         "taskId" => task_id,
         "configId" => config_id
       }),
       do: TaskHandler.handle_push_config_get(conn, id, task_id, config_id)

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.list", %{"taskId" => task_id}),
    do: TaskHandler.handle_push_config_list(conn, id, task_id)

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.delete", %{
         "taskId" => task_id,
         "configId" => config_id
       }),
       do: TaskHandler.handle_push_config_delete(conn, id, task_id, config_id)

  # Unknown method
  defp handle_rpc(conn, id, _unknown, _params),
    do: RpcErrors.send_error(conn, id, RpcErrors.code(:method_not_found), "Method not found")

  # -------------------------------------------------------------------
  # Request ID Plug
  # -------------------------------------------------------------------

  defp request_id(conn, _opts) do
    rid = Utils.new_id()
    Logger.metadata(request_id: rid)
    Plug.Conn.put_private(conn, :request_id, rid)
  end
end
