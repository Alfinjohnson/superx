defmodule Orchestrator.Protocol.MCP.Adapter do
  @moduledoc """
  MCP (Model Context Protocol) adapter for version 2024-11-05.

  Translates between internal Envelope and MCP JSON-RPC wire format.

  ## Wire Format

  MCP uses JSON-RPC 2.0 with slash-style method names:

  | Method | Description |
  |--------|-------------|
  | `initialize` | Establish connection and negotiate capabilities |
  | `tools/list` | Discover available tools |
  | `tools/call` | Execute a specific tool |
  | `resources/list` | List available resources |
  | `resources/read` | Read resource contents |
  | `prompts/list` | List available prompts |
  | `prompts/get` | Get prompt with arguments |
  | `sampling/createMessage` | Request LLM completion (server → client) |

  See: https://modelcontextprotocol.io/specification

  ## Transport Types

  MCP supports multiple transport types:
  - `streamable-http` - HTTP POST + Server-Sent Events
  - `sse` - Legacy SSE transport
  - `stdio` - Standard input/output for local processes

  ## Capabilities

  MCP uses capability negotiation during initialize:
  - Server capabilities: tools, resources, prompts
  - Client capabilities: sampling, roots, elicitation
  """

  @behaviour Orchestrator.Protocol.Behaviour

  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Utils

  @protocol_name "mcp"
  @protocol_version "2024-11-05"

  # -------------------------------------------------------------------
  # Protocol Metadata
  # -------------------------------------------------------------------

  @impl true
  def protocol_name, do: @protocol_name

  @impl true
  def protocol_version, do: @protocol_version

  # -------------------------------------------------------------------
  # Method Mapping
  # -------------------------------------------------------------------

  # MCP methods (2024-11-05 spec)
  @wire_to_canonical %{
    # Lifecycle
    "initialize" => :initialize,
    "notifications/initialized" => :initialized,
    "ping" => :ping,
    "shutdown" => :shutdown,
    # Tools
    "tools/list" => :list_tools,
    "tools/call" => :call_tool,
    "notifications/tools/list_changed" => :tools_changed,
    # Resources
    "resources/list" => :list_resources,
    "resources/templates/list" => :list_resource_templates,
    "resources/read" => :read_resource,
    "resources/subscribe" => :subscribe_resource,
    "resources/unsubscribe" => :unsubscribe_resource,
    "notifications/resources/list_changed" => :resources_changed,
    "notifications/resources/updated" => :resource_updated,
    # Prompts
    "prompts/list" => :list_prompts,
    "prompts/get" => :get_prompt,
    "notifications/prompts/list_changed" => :prompts_changed,
    # Sampling (server → client)
    "sampling/createMessage" => :create_message,
    # Elicitation (server → client)
    "elicitation/create" => :create_elicitation,
    # Roots (server → client)
    "roots/list" => :list_roots,
    "notifications/roots/list_changed" => :roots_changed,
    # Logging
    "logging/setLevel" => :set_log_level,
    "notifications/message" => :log_message,
    # Progress & cancellation
    "notifications/progress" => :progress,
    "notifications/cancelled" => :cancelled
  }

  @canonical_to_wire %{
    # Lifecycle
    initialize: "initialize",
    initialized: "notifications/initialized",
    ping: "ping",
    shutdown: "shutdown",
    # Tools
    list_tools: "tools/list",
    call_tool: "tools/call",
    tools_changed: "notifications/tools/list_changed",
    # Resources
    list_resources: "resources/list",
    list_resource_templates: "resources/templates/list",
    read_resource: "resources/read",
    subscribe_resource: "resources/subscribe",
    unsubscribe_resource: "resources/unsubscribe",
    resources_changed: "notifications/resources/list_changed",
    resource_updated: "notifications/resources/updated",
    # Prompts
    list_prompts: "prompts/list",
    get_prompt: "prompts/get",
    prompts_changed: "notifications/prompts/list_changed",
    # Sampling
    create_message: "sampling/createMessage",
    # Elicitation
    create_elicitation: "elicitation/create",
    # Roots
    list_roots: "roots/list",
    roots_changed: "notifications/roots/list_changed",
    # Logging
    set_log_level: "logging/setLevel",
    log_message: "notifications/message",
    # Progress
    progress: "notifications/progress",
    cancelled: "notifications/cancelled"
  }

  @impl true
  def normalize_method(wire_method) when is_binary(wire_method) do
    Map.get(@wire_to_canonical, wire_method, :unknown)
  end

  @impl true
  def wire_method(canonical) when is_atom(canonical) do
    Map.get(@canonical_to_wire, canonical, to_string(canonical))
  end

  # -------------------------------------------------------------------
  # Encode/Decode
  # -------------------------------------------------------------------

  @impl true
  def encode(%Envelope{} = env) do
    params = build_params(env)

    payload =
      %{
        "jsonrpc" => "2.0",
        "method" => wire_method(env.method)
      }
      |> maybe_add_id(env)
      |> maybe_add_params(params)

    {:ok, payload}
  end

  @impl true
  def decode(wire) when is_map(wire) do
    canonical = normalize_method(wire["method"])

    env =
      Envelope.new(%{
        protocol: @protocol_name,
        version: @protocol_version,
        method: canonical,
        payload: wire["params"] || %{},
        rpc_id: wire["id"],
        metadata: extract_metadata(wire)
      })

    {:ok, env}
  end

  @impl true
  def decode_stream_event(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"jsonrpc" => "2.0", "result" => result}} ->
        {:ok, {:result, result}}

      {:ok, %{"jsonrpc" => "2.0", "error" => error}} ->
        {:error, error}

      {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} ->
        # Notification or request from server
        {:ok, {:notification, normalize_method(method), msg["params"]}}

      {:ok, other} ->
        {:ok, other}

      {:error, _} = err ->
        err
    end
  end

  # -------------------------------------------------------------------
  # MCP-Specific Functions
  # -------------------------------------------------------------------

  @doc """
  Build an initialize request payload.
  """
  @spec build_initialize_request(map()) :: map()
  def build_initialize_request(opts \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => opts[:id] || Utils.new_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => build_client_capabilities(opts),
        "clientInfo" => %{
          "name" => opts[:client_name] || "orchestrator",
          "version" => opts[:client_version] || "0.1.0"
        }
      }
    }
  end

  @doc """
  Build client capabilities based on options.
  """
  @spec build_client_capabilities(map()) :: map()
  def build_client_capabilities(opts \\ %{}) do
    caps = %{}

    caps =
      if opts[:sampling], do: Map.put(caps, "sampling", %{}), else: caps

    caps =
      if opts[:roots], do: Map.put(caps, "roots", %{"listChanged" => true}), else: caps

    caps =
      if opts[:elicitation], do: Map.put(caps, "elicitation", %{}), else: caps

    caps
  end

  @doc """
  Parse server capabilities from initialize response.
  """
  @spec parse_server_capabilities(map()) :: map()
  def parse_server_capabilities(result) do
    %{
      protocol_version: result["protocolVersion"],
      server_info: result["serverInfo"],
      capabilities: %{
        tools: result["capabilities"]["tools"],
        resources: result["capabilities"]["resources"],
        prompts: result["capabilities"]["prompts"],
        logging: result["capabilities"]["logging"]
      }
    }
  end

  @doc """
  Build a tools/call request.
  """
  @spec build_tool_call(String.t(), map(), any()) :: map()
  def build_tool_call(tool_name, arguments, id \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "id" => id || Utils.new_id(),
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    }
  end

  @doc """
  Build a resources/read request.
  """
  @spec build_resource_read(String.t(), any()) :: map()
  def build_resource_read(uri, id \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "id" => id || Utils.new_id(),
      "method" => "resources/read",
      "params" => %{
        "uri" => uri
      }
    }
  end

  @doc """
  Check if a method is a notification (no response expected).
  """
  @spec notification?(atom()) :: boolean()
  def notification?(:initialized), do: true
  def notification?(:tools_changed), do: true
  def notification?(:resources_changed), do: true
  def notification?(:resource_updated), do: true
  def notification?(:prompts_changed), do: true
  def notification?(:roots_changed), do: true
  def notification?(:log_message), do: true
  def notification?(:progress), do: true
  def notification?(:cancelled), do: true
  def notification?(_), do: false

  @doc """
  Check if a method is a server-to-client request (bidirectional).
  """
  @spec server_request?(atom()) :: boolean()
  def server_request?(:create_message), do: true
  def server_request?(:create_elicitation), do: true
  def server_request?(:list_roots), do: true
  def server_request?(_), do: false

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp build_params(%Envelope{method: :initialize} = env) do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => env.payload["capabilities"] || build_client_capabilities(),
      "clientInfo" => env.payload["clientInfo"] || %{
        "name" => "orchestrator",
        "version" => "0.1.0"
      }
    }
  end

  defp build_params(%Envelope{method: :call_tool} = env) do
    %{
      "name" => env.payload["name"],
      "arguments" => env.payload["arguments"] || %{}
    }
  end

  defp build_params(%Envelope{method: :read_resource} = env) do
    %{"uri" => env.payload["uri"]}
  end

  defp build_params(%Envelope{method: :get_prompt} = env) do
    %{
      "name" => env.payload["name"],
      "arguments" => env.payload["arguments"] || %{}
    }
  end

  defp build_params(%Envelope{method: :subscribe_resource} = env) do
    %{"uri" => env.payload["uri"]}
  end

  defp build_params(%Envelope{method: :set_log_level} = env) do
    %{"level" => env.payload["level"]}
  end

  defp build_params(%Envelope{payload: payload}) when is_map(payload) do
    payload
  end

  defp build_params(_env), do: %{}

  defp maybe_add_id(payload, %Envelope{rpc_id: nil, method: method}) do
    # Notifications don't have IDs
    if notification?(method) do
      payload
    else
      Map.put(payload, "id", Utils.new_id())
    end
  end

  defp maybe_add_id(payload, %Envelope{rpc_id: id}) do
    Map.put(payload, "id", id)
  end

  defp maybe_add_params(payload, params) when map_size(params) == 0 do
    payload
  end

  defp maybe_add_params(payload, params) do
    Map.put(payload, "params", params)
  end

  defp extract_metadata(wire) do
    %{
      progress_token: get_in(wire, ["params", "_meta", "progressToken"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

# Backward compatibility alias
defmodule Orchestrator.Protocol.Adapters.MCP do
  @moduledoc false
  defdelegate protocol_name(), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate protocol_version(), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate normalize_method(wire_method), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate wire_method(canonical), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate encode(env), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate decode(wire), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate decode_stream_event(data), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate build_initialize_request(opts \\ %{}), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate build_client_capabilities(opts \\ %{}), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate parse_server_capabilities(result), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate build_tool_call(tool_name, arguments, id \\ nil), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate build_resource_read(uri, id \\ nil), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate notification?(method), to: Orchestrator.Protocol.MCP.Adapter
  defdelegate server_request?(method), to: Orchestrator.Protocol.MCP.Adapter
end
