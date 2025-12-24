defmodule Orchestrator.Protocol.MCP.Transport.HTTP do
  @moduledoc """
  HTTP transport for MCP protocol.

  Supports two modes:
  - `streamable-http` - HTTP POST for requests, optional SSE for streaming
  - `sse` - Legacy SSE-only transport

  ## Streamable HTTP

  The modern MCP transport uses HTTP POST for all client→server messages:

  ```
  POST /mcp HTTP/1.1
  Content-Type: application/json

  {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
  ```

  For streaming responses (subscriptions, long-running operations),
  the server may return SSE:

  ```
  HTTP/1.1 200 OK
  Content-Type: text/event-stream

  data: {"jsonrpc": "2.0", "id": 1, "result": {...}}
  ```

  ## Authentication

  Supports:
  - Bearer tokens (Authorization header)
  - Custom headers (X-API-Key, etc.)
  """

  @behaviour Orchestrator.Protocol.MCP.Transport.Behaviour

  require Logger

  alias Orchestrator.Utils

  defstruct [
    :url,
    :headers,
    :timeout,
    :type,
    :session_id,
    :streaming_pid,
    :pending_requests
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          headers: map(),
          timeout: non_neg_integer(),
          type: :http | :sse,
          session_id: String.t() | nil,
          streaming_pid: pid() | nil,
          pending_requests: map()
        }

  # -------------------------------------------------------------------
  # Behaviour Implementation
  # -------------------------------------------------------------------

  @impl true
  def connect(config) do
    state = %__MODULE__{
      url: config.url,
      headers: Map.to_list(config.headers || %{}),
      timeout: config.timeout || 30_000,
      type: config.type || :http,
      session_id: nil,
      streaming_pid: nil,
      pending_requests: %{}
    }

    # Validate URL
    case URI.parse(state.url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        Logger.debug("MCP HTTP transport connected to #{state.url}")
        {:ok, state}

      _ ->
        {:error, {:invalid_url, state.url}}
    end
  end

  @impl true
  def send_message(state, message) do
    # For notifications, just send without expecting response
    if is_notification?(message) do
      case do_post(state, message) do
        {:ok, _response} -> {:ok, state}
        {:error, _} = err -> err
      end
    else
      # For requests, wait for response
      request(state, message, state.timeout)
    end
  end

  @impl true
  def request(state, message, timeout) do
    message = ensure_id(message)
    request_id = message["id"]

    Logger.debug("MCP HTTP request: #{message["method"]} id=#{request_id}")

    case do_post(state, message, timeout) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # JSON response
        {:ok, state, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # SSE or text response - need to parse
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, state, decoded}
          {:error, _} -> {:error, {:invalid_json, body}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @impl true
  def start_streaming(state, receiver_pid) do
    # Start SSE connection for streaming
    url = state.url
    headers = [{"Accept", "text/event-stream"} | state.headers]

    # Spawn a process to handle SSE stream
    pid =
      spawn_link(fn ->
        stream_sse(url, headers, receiver_pid)
      end)

    {:ok, %{state | streaming_pid: pid}}
  end

  @impl true
  def stop_streaming(%{streaming_pid: nil} = state) do
    {:ok, state}
  end

  def stop_streaming(%{streaming_pid: pid} = state) do
    Process.exit(pid, :normal)
    {:ok, %{state | streaming_pid: nil}}
  end

  @impl true
  def close(state) do
    if state.streaming_pid do
      Process.exit(state.streaming_pid, :normal)
    end

    :ok
  end

  @impl true
  def connected?(%{url: url}) when is_binary(url), do: true
  def connected?(_), do: false

  @impl true
  def info(state) do
    %{
      transport: :http,
      url: state.url,
      type: state.type,
      session_id: state.session_id,
      streaming: state.streaming_pid != nil
    }
  end

  # -------------------------------------------------------------------
  # HTTP Client Functions
  # -------------------------------------------------------------------

  defp do_post(state, payload, timeout \\ nil) do
    timeout = timeout || state.timeout

    headers =
      [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"}
      ] ++ state.headers

    # Add session ID if we have one
    headers =
      if state.session_id do
        [{"Mcp-Session-Id", state.session_id} | headers]
      else
        headers
      end

    Req.post(state.url,
      json: payload,
      headers: headers,
      receive_timeout: timeout,
      finch: Orchestrator.Finch
    )
  end

  # -------------------------------------------------------------------
  # SSE Streaming
  # -------------------------------------------------------------------

  defp stream_sse(url, headers, receiver_pid) do
    case Req.get(url, headers: headers, into: :self, finch: Orchestrator.Finch) do
      {:ok, response} ->
        receive_sse_events(response, receiver_pid, "")

      {:error, reason} ->
        send(receiver_pid, {:mcp_error, reason})
    end
  end

  defp receive_sse_events(response, receiver_pid, buffer) do
    receive do
      {^response, {:data, data}} ->
        # Accumulate data and parse SSE events
        buffer = buffer <> data
        {events, remaining} = parse_sse_buffer(buffer)

        Enum.each(events, fn event ->
          case parse_sse_event(event) do
            {:ok, message} ->
              send(receiver_pid, {:mcp_message, message})

            {:error, reason} ->
              Logger.warning("Failed to parse SSE event: #{inspect(reason)}")
          end
        end)

        receive_sse_events(response, receiver_pid, remaining)

      {^response, :done} ->
        send(receiver_pid, {:mcp_closed, :normal})

      {^response, {:error, reason}} ->
        send(receiver_pid, {:mcp_error, reason})
    after
      60_000 ->
        # Keepalive timeout
        send(receiver_pid, {:mcp_error, :timeout})
    end
  end

  defp parse_sse_buffer(buffer) do
    # Split on double newlines (SSE event separator)
    case String.split(buffer, "\n\n", parts: 2) do
      [event, rest] -> {[event], rest}
      [incomplete] -> {[], incomplete}
    end
  end

  defp parse_sse_event(event) do
    # Parse SSE event format: "data: {...}\n"
    lines = String.split(event, "\n")

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(&1, "data:"))
      |> Enum.map(&String.trim/1)
      |> Enum.join("")

    if data != "" do
      Jason.decode(data)
    else
      {:error, :empty_event}
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp is_notification?(message) do
    # Notifications don't have an "id" field
    not Map.has_key?(message, "id")
  end

  defp ensure_id(%{"id" => _} = message), do: message
  defp ensure_id(message), do: Map.put(message, "id", Utils.new_id())
end

# Backward compatibility alias
defmodule Orchestrator.MCP.Transport.HTTP do
  @moduledoc false
  defdelegate connect(config), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate send_message(state, message), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate request(state, message, timeout), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate start_streaming(state, receiver_pid), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate stop_streaming(state), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate close(state), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate connected?(state), to: Orchestrator.Protocol.MCP.Transport.HTTP
  defdelegate info(state), to: Orchestrator.Protocol.MCP.Transport.HTTP
end
