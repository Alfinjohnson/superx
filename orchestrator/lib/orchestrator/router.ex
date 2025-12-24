defmodule Orchestrator.Router do
  @moduledoc false

  use Plug.Router
  require Logger

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Infra.Cluster
  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PushConfig
  alias Orchestrator.Utils

  plug(:request_id)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["*/*"]
  )

  plug(:match)
  plug(:dispatch)

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

  post "/rpc" do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload ->
        handle_rpc(conn, id, method, Map.get(payload, "params", %{}))

      _ ->
        send_error(conn, nil, -32600, "Invalid Request")
    end
  end

  # Agent card endpoint - serves agent cards through the orchestrator
  get "/agents/:agent_id/.well-known/agent-card.json" do
    case AgentStore.fetch(agent_id) do
      nil ->
        send_resp(conn, 404, Jason.encode!(%{error: "Agent not found"}))

      agent ->
        serve_agent_card(conn, agent_id, agent)
    end
  end

  # A2A proxy endpoint - forwards JSON-RPC requests to agents through the orchestrator
  post "/agents/:agent_id" do
    case conn.body_params do
      %{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload ->
        proxy_a2a_request(conn, agent_id, id, method, payload)

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

  defp handle_rpc(conn, id, "message.send", params) do
    with {:ok, agent_id} <- fetch_agent_id(params),
         {:ok, _agent} <- fetch_agent(agent_id),
         env = build_envelope("send", params, id, agent_id),
         {:ok, forwarded} <- AgentWorker.call(agent_id, env) do
      maybe_store_task(forwarded, env.webhook)

      send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => forwarded})
      )
    else
      {:error, :no_agent} ->
        send_error(conn, id, -32602, "agentId is required")

      {:error, :agent_missing} ->
        send_error(conn, id, -32001, "Agent not found")

      {:error, :agent_not_found} ->
        send_error(conn, id, -32001, "Agent not found")

      {:error, :circuit_open} ->
        send_error(conn, id, -32002, "Agent circuit breaker open")

      {:error, :too_many_requests} ->
        send_error(conn, id, -32003, "Agent overloaded")

      {:error, {:remote, status, body}} ->
        send_error(conn, id, -32099, "Remote agent error #{status}: #{inspect(body)}")

      {:error, :decode} ->
        send_error(conn, id, -32700, "Invalid JSON from remote agent")

      {:error, :timeout} ->
        send_error(conn, id, -32098, "Agent call timed out")

      {:error, %{"code" => code, "message" => msg}} ->
        send_error(conn, id, code, msg)

      {:error, other} ->
        send_error(conn, id, -32099, "Unknown error: #{inspect(other)}")
    end
  end

  defp handle_rpc(conn, id, "message.stream", params) do
    with {:ok, agent_id} <- fetch_agent_id(params),
         {:ok, _agent} <- fetch_agent(agent_id),
         env = build_envelope("stream", params, id, agent_id),
         {:ok, _streaming} <- AgentWorker.stream(agent_id, env, self()) do
      receive do
        {:stream_init, ^id, result} ->
          maybe_store_task(result, env.webhook)

          send_resp(
            conn,
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          )

        {:stream_error, ^id, status} ->
          send_error(conn, id, -32099, "Remote stream error #{status}")
      after
        5_000 -> send_error(conn, id, -32098, "Stream initialization timed out")
      end
    else
      {:error, :no_agent} ->
        send_error(conn, id, -32602, "agentId is required")

      {:error, :agent_missing} ->
        send_error(conn, id, -32001, "Agent not found")

      {:error, :agent_not_found} ->
        send_error(conn, id, -32001, "Agent not found")

      {:error, :circuit_open} ->
        send_error(conn, id, -32002, "Agent circuit breaker open")

      {:error, :too_many_requests} ->
        send_error(conn, id, -32003, "Agent overloaded")

      {:error, {:remote, status, body}} ->
        send_error(conn, id, -32099, "Remote agent error #{status}: #{inspect(body)}")

      {:error, :decode} ->
        send_error(conn, id, -32700, "Invalid JSON from remote agent")

      {:error, :timeout} ->
        send_error(conn, id, -32098, "Stream initialization timed out")

      {:error, %{"code" => code, "message" => msg}} ->
        send_error(conn, id, code, msg)

      {:error, other} ->
        send_error(conn, id, -32099, "Unknown error: #{inspect(other)}")
    end
  end

  defp handle_rpc(conn, id, "agents.list", _params) do
    agents = AgentStore.list()
    send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => agents}))
  end

  defp handle_rpc(conn, id, "agents.get", %{"id" => agent_id}) do
    case AgentStore.fetch(agent_id) do
      nil ->
        send_error(conn, id, -32010, "Agent not found")

      agent ->
        send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => agent}))
    end
  end

  defp handle_rpc(conn, id, "agents.upsert", %{"agent" => agent}) do
    case AgentStore.upsert(agent) do
      {:ok, stored} ->
        send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => stored}))

      {:error, :invalid} ->
        send_error(conn, id, -32602, "Invalid agent payload (id and url required)")
    end
  end

  defp handle_rpc(conn, id, "agents.delete", %{"id" => agent_id}) do
    AgentStore.delete(agent_id)
    send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => true}))
  end

  defp handle_rpc(conn, id, "agents.refreshCard", %{"id" => _agent_id}) do
    # Card refresh is not implemented in memory-only mode
    send_error(conn, id, -32601, "agents.refreshCard not implemented in memory-only mode")
  end

  defp handle_rpc(conn, id, "agents.health", %{"id" => agent_id}) do
    case AgentWorker.health(agent_id) do
      {:ok, health} ->
        send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => health}))

      {:error, :agent_not_found} ->
        send_error(conn, id, -32010, "Agent not found")
    end
  end

  defp handle_rpc(conn, id, "agents.health", _params) do
    agents = AgentStore.list()

    healths =
      Enum.map(agents, fn agent ->
        case AgentWorker.health(agent["id"]) do
          {:ok, h} -> h
          {:error, _} -> %{agent_id: agent["id"], breaker_state: :unknown}
        end
      end)

    send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => healths}))
  end

  defp handle_rpc(conn, id, "tasks.get", %{"taskId" => task_id}) do
    case TaskStore.get(task_id) do
      nil ->
        send_error(conn, id, -32004, "Task not found")

      task ->
        send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => task}))
    end
  end

  defp handle_rpc(conn, id, "tasks.subscribe", %{"taskId" => task_id}) do
    stream_task(conn, id, task_id)
  end

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.set", %{
         "taskId" => task_id,
         "config" => cfg
       }) do
    case TaskStore.get(task_id) do
      nil ->
        send_error(conn, id, -32004, "Task not found")

      _task ->
        case PushConfig.set(task_id, cfg) do
          {:ok, saved} ->
            send_resp(
              conn,
              200,
              Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => saved})
            )

          {:error, :invalid} ->
            send_error(conn, id, -32602, "Invalid push config")
        end
    end
  end

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.get", %{
         "taskId" => task_id,
         "configId" => config_id
       }) do
    case PushConfig.get(task_id, config_id) do
      nil ->
        send_error(conn, id, -32004, "Push notification config not found")

      cfg ->
        send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => cfg}))
    end
  end

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.list", %{"taskId" => task_id}) do
    cfgs = PushConfig.list(task_id)
    send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => cfgs}))
  end

  defp handle_rpc(conn, id, "tasks.pushNotificationConfig.delete", %{
         "taskId" => task_id,
         "configId" => config_id
       }) do
    PushConfig.delete(task_id, config_id)
    send_resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => true}))
  end

  defp handle_rpc(conn, id, _unknown, _params) do
    send_error(conn, id, -32601, "Method not found")
  end

  defp fetch_agent_id(%{"agentId" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_agent_id(_), do: {:error, :no_agent}

  defp fetch_agent(agent_id) do
    case AgentStore.fetch(agent_id) do
      nil -> {:error, :agent_missing}
      agent -> {:ok, agent}
    end
  end

  defp build_envelope(method, params, rpc_id, agent_id) do
    # Extract per-request webhook from metadata if present
    webhook = get_in(params, ["metadata", "webhook"])

    Envelope.new(%{
      method: method,
      task_id: Map.get(params, "taskId"),
      context_id: Map.get(params, "contextId"),
      message: Map.get(params, "message"),
      payload: params,
      agent_id: agent_id,
      rpc_id: rpc_id,
      webhook: webhook
    })
  end

  defp maybe_store_task(%{"id" => task_id} = task, per_request_webhook) do
    case TaskStore.put(task) do
      :ok -> :ok
      {:error, :terminal} -> Logger.info("task already terminal; skipped store")
      {:error, _} -> Logger.warning("failed to store task")
    end

    # Also deliver per-request webhook if provided (in addition to stored configs)
    if per_request_webhook do
      PushConfig.deliver_event(task_id, %{"task" => task}, per_request_webhook)
    end

    :ok
  end

  defp maybe_store_task(_, _), do: :ok

  defp request_id(conn, _opts) do
    rid = Utils.new_id()
    Logger.metadata(request_id: rid)
    Plug.Conn.put_private(conn, :request_id, rid)
  end

  defp send_error(conn, id, code, message) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "error" => %{code: code, message: message}}
    send_resp(conn, 400, Jason.encode!(payload))
  end

  defp stream_task(conn, id, task_id) do
    case TaskStore.subscribe(task_id) do
      nil ->
        send_error(conn, id, -32004, "Task not found")

      task ->
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> send_chunked(200)

        {:ok, conn} = send_event(conn, %{jsonrpc: "2.0", id: id, result: task})
        loop_events(conn, id, task_id)
    end
  end

  defp loop_events(conn, id, task_id) do
    receive do
      {:task_update, task} ->
        {:ok, conn} = send_event(conn, %{jsonrpc: "2.0", id: id, result: task})

        if Utils.terminal_state?(get_in(task, ["status", "state"])) do
          Plug.Conn.halt(conn)
        else
          loop_events(conn, id, task_id)
        end

      {:halt, _} ->
        Plug.Conn.halt(conn)
    after
      15_000 ->
        # keep-alive comment to prevent idle timeouts
        {:ok, conn} = Plug.Conn.chunk(conn, ": keep-alive\n\n")
        loop_events(conn, id, task_id)
    end
  end

  defp send_event(conn, map) do
    json = Jason.encode!(map)
    Plug.Conn.chunk(conn, "data: " <> json <> "\n\n")
  end

  # --- Agent Card & A2A Proxy Helpers ---

  defp get_orchestrator_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port = conn.port

    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp serve_agent_card(conn, agent_id, agent) do
    protocol = agent["protocol"] || "a2a"
    protocol_version = agent["protocolVersion"] || "0.3.0"

    # Use protocol-specific card handling
    case Orchestrator.Protocol.adapter_for(protocol, protocol_version) do
      {:ok, adapter} ->
        serve_card_with_adapter(conn, agent_id, agent, adapter)

      {:error, _} ->
        # Fallback for unknown protocols - try generic card serving
        serve_card_generic(conn, agent_id, agent)
    end
  end

  defp serve_card_with_adapter(conn, agent_id, agent, adapter) do
    orchestrator_url = get_orchestrator_url(conn)
    cached_card = get_in(agent, ["metadata", "agentCard"])

    cond do
      # 1. Check if we have a valid cached card with required fields
      cached_card != nil and adapter.valid_card?(cached_card) ->
        card =
          cached_card
          |> adapter.normalize_agent_card()
          |> Map.put("url", "#{orchestrator_url}/agents/#{agent_id}")

        send_resp(conn, 200, Jason.encode!(card))

      # 2. Check if there's an explicit card URL to fetch from
      true ->
        card_url = adapter.resolve_card_url(agent)
        fetch_and_serve_card(conn, agent_id, card_url, adapter, orchestrator_url)
    end
  end

  defp serve_card_generic(conn, agent_id, agent) do
    orchestrator_url = get_orchestrator_url(conn)
    cached_card = get_in(agent, ["metadata", "agentCard"])

    if cached_card != nil do
      card = Map.put(cached_card, "url", "#{orchestrator_url}/agents/#{agent_id}")
      send_resp(conn, 200, Jason.encode!(card))
    else
      # Fallback to well-known path
      card_url = "#{agent["url"]}/.well-known/agent.json"
      proxy_agent_card(conn, agent_id, card_url, orchestrator_url)
    end
  end

  defp fetch_and_serve_card(conn, agent_id, card_url, adapter, orchestrator_url) do
    case Req.get(card_url, finch: Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        card =
          body
          |> adapter.normalize_agent_card()
          |> Map.put("url", "#{orchestrator_url}/agents/#{agent_id}")

        send_resp(conn, 200, Jason.encode!(card))

      {:ok, %{status: status}} ->
        send_resp(
          conn,
          status,
          Jason.encode!(%{error: "Failed to fetch agent card", status: status})
        )

      {:error, reason} ->
        Logger.warning("Failed to fetch agent card from #{card_url}: #{inspect(reason)}")
        send_resp(conn, 502, Jason.encode!(%{error: "Failed to reach agent"}))
    end
  end

  defp proxy_agent_card(conn, agent_id, card_url, orchestrator_url) do
    case Req.get(card_url, finch: Orchestrator.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        card = Map.put(body, "url", "#{orchestrator_url}/agents/#{agent_id}")
        send_resp(conn, 200, Jason.encode!(card))

      {:ok, %{status: status}} ->
        send_resp(conn, status, Jason.encode!(%{error: "Failed to fetch agent card"}))

      {:error, _} ->
        send_resp(conn, 502, Jason.encode!(%{error: "Failed to reach agent"}))
    end
  end

  defp proxy_a2a_request(conn, agent_id, rpc_id, wire_method, payload) do
    Logger.debug("A2A proxy request: method=#{wire_method} agent=#{agent_id}")

    # Get the agent to determine protocol version
    case AgentStore.fetch(agent_id) do
      nil ->
        send_error(conn, rpc_id, -32001, "Agent not found")

      agent ->
        # Get protocol adapter for this agent (returns module directly)
        adapter = Orchestrator.Protocol.adapter_for_agent(agent)
        # Normalize wire method to canonical method using adapter
        canonical = adapter.normalize_method(wire_method)
        handle_canonical_method(conn, agent_id, agent, adapter, canonical, rpc_id, payload)
    end
  end

  # Handle canonical methods - protocol-agnostic routing
  defp handle_canonical_method(conn, agent_id, agent, adapter, canonical, rpc_id, payload) do
    params = Map.get(payload, "params", %{}) |> Map.put("agentId", agent_id)

    case canonical do
      # Core messaging - handle through orchestrator
      :send_message ->
        handle_rpc(conn, rpc_id, "message.send", params)

      :stream_message ->
        handle_rpc(conn, rpc_id, "message.stream", params)

      :subscribe_task ->
        handle_rpc(conn, rpc_id, "message.stream", params)

      # Task management - some handled locally, some forwarded
      :get_task ->
        handle_rpc(conn, rpc_id, "tasks.get", params)

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

  defp forward_to_agent(conn, agent_id, agent, _adapter, rpc_id, payload) do
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
        send_error(conn, rpc_id, -32099, "Failed to reach agent")
    end
  end
end
