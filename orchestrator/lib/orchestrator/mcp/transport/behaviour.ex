defmodule Orchestrator.MCP.Transport.Behaviour do
  @moduledoc """
  Behaviour for MCP transport implementations.

  MCP supports multiple transport mechanisms:
  - HTTP (streamable-http) - HTTP POST with optional SSE for streaming
  - SSE (legacy) - Server-Sent Events only
  - STDIO - Standard input/output for local processes

  Each transport must implement this behaviour to provide a consistent
  interface for the MCP.Session GenServer.

  ## Connection Lifecycle

  1. `connect/1` - Establish connection (spawn process, open HTTP connection)
  2. `send/2` - Send JSON-RPC message
  3. `receive/1` - Receive response or notification
  4. `close/1` - Clean up resources

  ## Message Flow

  ```
  Session                    Transport                    Server
     |                           |                           |
     |-- send(msg) ------------>|                           |
     |                          |-- HTTP POST/write ------->|
     |                          |<-- Response/SSE ----------|
     |<-- {:ok, response} ------|                           |
  ```
  """

  @type transport_config :: %{
          type: :http | :sse | :stdio,
          url: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()] | nil,
          env: map() | nil,
          headers: map() | nil,
          timeout: non_neg_integer() | nil
        }

  @type transport_state :: term()
  @type message :: map()

  @doc """
  Connect to the MCP server.

  For HTTP transports, this may just validate the URL.
  For STDIO transports, this spawns the server process.

  Returns `{:ok, state}` on success or `{:error, reason}` on failure.
  """
  @callback connect(transport_config()) :: {:ok, transport_state()} | {:error, term()}

  @doc """
  Send a JSON-RPC message to the server.

  For HTTP, this makes a POST request.
  For STDIO, this writes to stdin.

  Notifications don't expect a response, so they return `:ok`.
  Requests return `{:ok, response}` or `{:error, reason}`.
  """
  @callback send_message(transport_state(), message()) ::
              {:ok, transport_state()} | {:ok, transport_state(), message()} | {:error, term()}

  @doc """
  Send a request and wait for response.

  This is a blocking call that sends the message and waits for the
  corresponding response (matched by JSON-RPC id).
  """
  @callback request(transport_state(), message(), timeout :: non_neg_integer()) ::
              {:ok, transport_state(), message()} | {:error, term()}

  @doc """
  Start receiving streaming messages (SSE or continuous output).

  The caller process will receive messages as:
  - `{:mcp_message, message}` for JSON-RPC messages
  - `{:mcp_error, reason}` for errors
  - `{:mcp_closed, reason}` when connection closes
  """
  @callback start_streaming(transport_state(), pid()) ::
              {:ok, transport_state()} | {:error, term()}

  @doc """
  Stop receiving streaming messages.
  """
  @callback stop_streaming(transport_state()) :: {:ok, transport_state()}

  @doc """
  Close the transport connection.

  For HTTP, this closes any persistent connections.
  For STDIO, this terminates the server process.
  """
  @callback close(transport_state()) :: :ok

  @doc """
  Check if the transport is connected and healthy.
  """
  @callback connected?(transport_state()) :: boolean()

  @doc """
  Get transport info for debugging/logging.
  """
  @callback info(transport_state()) :: map()

  # -------------------------------------------------------------------
  # Helper Functions
  # -------------------------------------------------------------------

  alias Orchestrator.MCP.Transport.Docker

  @doc """
  Build a transport module from config type.
  """
  @spec transport_module(atom() | String.t()) :: module()
  def transport_module(:http), do: Orchestrator.MCP.Transport.HTTP
  def transport_module(:sse), do: Orchestrator.MCP.Transport.HTTP
  def transport_module("streamable-http"), do: Orchestrator.MCP.Transport.HTTP
  def transport_module("sse"), do: Orchestrator.MCP.Transport.HTTP
  def transport_module(:stdio), do: Orchestrator.MCP.Transport.STDIO
  def transport_module("stdio"), do: Orchestrator.MCP.Transport.STDIO

  @doc """
  Parse transport config from agent configuration.

  Handles OCI package configs by transforming them into STDIO transport.
  """
  @spec parse_config(map()) :: {:ok, transport_config()} | {:error, term()}
  def parse_config(%{"transport" => transport} = _agent) when is_map(transport) do
    # Check for OCI package format
    if Docker.oci_package?(transport) do
      case Docker.prepare_transport(transport) do
        {:ok, stdio_config} ->
          {:ok, parse_stdio_config(stdio_config)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, parse_standard_transport(transport)}
    end
  end

  def parse_config(%{"url" => url} = agent) do
    # Legacy format - assume HTTP
    {:ok, %{
      type: :http,
      url: url,
      command: nil,
      args: [],
      env: %{},
      headers: build_headers(agent),
      timeout: 30_000
    }}
  end

  def parse_config(_), do: {:error, :invalid_transport_config}

  @doc """
  Parse config without OCI preparation (for backwards compatibility).
  Returns config directly without {:ok, _} wrapper.
  """
  @spec parse_config!(map()) :: transport_config()
  def parse_config!(config) do
    case parse_config(config) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise "Failed to parse transport config: #{inspect(reason)}"
    end
  end

  defp parse_standard_transport(transport) do
    %{
      type: parse_type(transport["type"]),
      url: transport["url"],
      command: transport["command"],
      args: transport["args"] || [],
      env: transport["env"] || %{},
      headers: transport["headers"] || %{},
      timeout: transport["timeout"] || 30_000
    }
  end

  defp parse_stdio_config(config) do
    %{
      type: :stdio,
      url: nil,
      command: config["command"],
      args: config["args"] || [],
      env: config["env"] || %{},
      headers: %{},
      timeout: config["timeout"] || 30_000
    }
  end

  defp parse_type("streamable-http"), do: :http
  defp parse_type("sse"), do: :sse
  defp parse_type("stdio"), do: :stdio
  defp parse_type(type) when is_atom(type), do: type
  defp parse_type(_), do: :http

  defp build_headers(%{"bearer" => token}) when is_binary(token) and token != "" do
    %{"Authorization" => "Bearer #{token}"}
  end

  defp build_headers(_), do: %{}
end
