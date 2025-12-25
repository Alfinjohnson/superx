defmodule Orchestrator.Web.Handlers.MCPProxy do
  @moduledoc """
  Simple MCP SSE proxy - routes requests to backend MCP servers.

  Similar to A2A proxy, just forwards:
  - GET /mcp/:agent_id -> backend SSE connection
  - POST /mcp/:agent_id/messages -> backend /messages endpoint
  """

  require Logger

  alias Orchestrator.Agent.Store, as: AgentStore

  @doc """
  Handle SSE connection - proxy to backend MCP server's /sse endpoint
  """
  def handle_sse(conn, agent_id) do
    case AgentStore.fetch(agent_id) do
      nil ->
        Logger.warning("MCP proxy: agent not found: #{agent_id}")
        Plug.Conn.send_resp(conn, 404, "Agent not found: #{agent_id}")

      agent ->
        Logger.info("MCP proxy: agent=#{agent_id} protocol=#{inspect(agent["protocol"])}")
        if agent["protocol"] == "mcp" do
          proxy_sse(conn, agent)
        else
          Plug.Conn.send_resp(conn, 400, "Agent #{agent_id} is not an MCP agent (protocol: #{agent["protocol"]})")
        end
    end
  end

  @doc """
  Handle POST /messages - proxy to backend MCP server
  """
  def handle_message(conn, agent_id) do
    case AgentStore.fetch(agent_id) do
      nil ->
        Plug.Conn.send_resp(conn, 404, "Agent not found: #{agent_id}")

      agent ->
        if agent["protocol"] == "mcp" do
          proxy_message(conn, agent)
        else
          Plug.Conn.send_resp(conn, 400, "Agent #{agent_id} is not an MCP agent")
        end
    end
  end

  # Proxy SSE connection to backend
  defp proxy_sse(conn, agent) do
    backend_url = get_backend_sse_url(agent)
    Logger.info("MCP SSE proxy: connecting to #{backend_url}")

    # Set up SSE headers for client
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("connection", "keep-alive")
      |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
      |> Plug.Conn.send_chunked(200)

    # Connect to backend SSE and relay events
    case start_backend_sse(backend_url) do
      {:ok, stream_pid} ->
        sse_relay_loop(conn, stream_pid)

      {:error, reason} ->
        Logger.error("Failed to connect to backend SSE: #{inspect(reason)}")
        conn
    end
  end

  # Proxy POST message to backend
  defp proxy_message(conn, agent) do
    backend_url = get_backend_messages_url(agent, conn.query_params)
    body = Jason.encode!(conn.body_params)

    Logger.info("MCP proxy POST: #{backend_url}")
    Logger.debug("MCP proxy body: #{body}")

    case :httpc.request(
           :post,
           {String.to_charlist(backend_url), [], ~c"application/json", body},
           [{:timeout, 30_000}],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, status, _}, _headers, response_body}} ->
        Logger.debug("MCP proxy response: #{status} - #{response_body}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(status, response_body)

      {:error, reason} ->
        Logger.error("MCP proxy error: #{inspect(reason)}")

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(502, Jason.encode!(%{error: "Backend error: #{inspect(reason)}"}))
    end
  end

  # Get backend SSE URL from agent config
  defp get_backend_sse_url(agent) do
    base_url = agent["url"] || get_in(agent, ["transport", "url"])
    "#{base_url}/sse"
  end

  # Get backend messages URL, preserving query params
  defp get_backend_messages_url(agent, query_params) do
    base_url = agent["url"] || get_in(agent, ["transport", "url"])

    if map_size(query_params) > 0 do
      query_string = URI.encode_query(query_params)
      "#{base_url}/messages?#{query_string}"
    else
      "#{base_url}/messages"
    end
  end

  # Start streaming from backend SSE
  defp start_backend_sse(url) do
    parent = self()

    pid =
      spawn_link(fn ->
        case :httpc.request(
               :get,
               {String.to_charlist(url), [{~c"Accept", ~c"text/event-stream"}]},
               [{:timeout, :infinity}],
               [{:sync, false}, {:stream, :self}]
             ) do
          {:ok, request_id} ->
            backend_sse_loop(parent, request_id)

          {:error, reason} ->
            send(parent, {:backend_error, reason})
        end
      end)

    # Wait briefly for connection or error
    receive do
      {:backend_error, reason} -> {:error, reason}
    after
      100 -> {:ok, pid}
    end
  end

  # Receive SSE data from backend and forward to parent
  defp backend_sse_loop(parent, request_id) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        backend_sse_loop(parent, request_id)

      {:http, {^request_id, :stream, data}} ->
        send(parent, {:backend_data, data})
        backend_sse_loop(parent, request_id)

      {:http, {^request_id, :stream_end, _headers}} ->
        send(parent, :backend_closed)

      {:http, {^request_id, {:error, reason}}} ->
        send(parent, {:backend_error, reason})

      :stop ->
        :httpc.cancel_request(request_id)
    end
  end

  # Relay SSE events from backend to client
  defp sse_relay_loop(conn, stream_pid) do
    receive do
      {:backend_data, data} ->
        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} ->
            sse_relay_loop(conn, stream_pid)

          {:error, _reason} ->
            send(stream_pid, :stop)
            conn
        end

      :backend_closed ->
        Logger.info("Backend SSE closed")
        conn

      {:backend_error, reason} ->
        Logger.error("Backend SSE error: #{inspect(reason)}")
        conn
    after
      60_000 ->
        # Timeout - connection may be dead
        send(stream_pid, :stop)
        conn
    end
  end
end
