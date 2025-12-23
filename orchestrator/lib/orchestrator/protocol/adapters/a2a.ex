defmodule Orchestrator.Protocol.Adapters.A2A do
  @moduledoc """
  A2A protocol adapter for version 0.3.0.

  Translates between internal Envelope and A2A JSON-RPC wire format.

  ## Wire Format

  A2A 0.3.0 uses JSON-RPC 2.0 with PascalCase method names:

  | Method | Description |
  |--------|-------------|
  | `SendMessage` | Send a message to an agent |
  | `SendStreamingMessage` | Send message with streaming response |
  | `GetTask` | Get task state |
  | `CancelTask` | Cancel a running task |
  | `ListTasks` | List tasks |
  | `SubscribeToTask` | Subscribe to task updates (SSE) |

  See: https://a2a-protocol.org/v0.3.0/specification

  ## Agent Card

  Agent cards are served at `/.well-known/agent-card.json` and must include:
  - `name`, `version`, `url` (required)
  - `skills` with `tags` array (required by Google ADK)
  - `capabilities`, `defaultInputModes`, `defaultOutputModes` (optional)

  ## Compatibility

  This adapter also supports slash-style method names (e.g., `message/send`)
  for compatibility with some clients.
  """

  @behaviour Orchestrator.Protocol.Behaviour

  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Utils

  @protocol_name "a2a"
  @protocol_version "0.3.0"
  @well_known_path "/.well-known/agent-card.json"

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

  # A2A 0.3.0 uses PascalCase method names (Section 9.4 of spec)
  # Also support slash-style for compatibility

  @wire_to_canonical %{
    # Core messaging - PascalCase (A2A 0.3.0 spec)
    "SendMessage" => :send_message,
    "SendStreamingMessage" => :stream_message,
    # Core messaging - slash-style (compatibility)
    "message/send" => :send_message,
    "message/stream" => :stream_message,
    # Task management - PascalCase
    "GetTask" => :get_task,
    "ListTasks" => :list_tasks,
    "CancelTask" => :cancel_task,
    "SubscribeToTask" => :subscribe_task,
    # Task management - slash-style
    "tasks/get" => :get_task,
    "tasks/list" => :list_tasks,
    "tasks/cancel" => :cancel_task,
    "tasks/subscribe" => :subscribe_task,
    # Push notifications - PascalCase
    "SetTaskPushNotificationConfig" => :set_push_config,
    "GetTaskPushNotificationConfig" => :get_push_config,
    "ListTaskPushNotificationConfig" => :list_push_configs,
    "DeleteTaskPushNotificationConfig" => :delete_push_config,
    # Push notifications - slash-style
    "tasks/pushNotificationConfig/set" => :set_push_config,
    "tasks/pushNotificationConfig/get" => :get_push_config,
    "tasks/pushNotificationConfig/list" => :list_push_configs,
    "tasks/pushNotificationConfig/delete" => :delete_push_config,
    # Agent card
    "GetExtendedAgentCard" => :get_agent_card,
    "agent/card" => :get_agent_card
  }

  # Use slash-style for outbound wire format (more widely supported)
  @canonical_to_wire %{
    send_message: "message/send",
    stream_message: "message/stream",
    get_task: "tasks/get",
    list_tasks: "tasks/list",
    cancel_task: "tasks/cancel",
    subscribe_task: "tasks/subscribe",
    set_push_config: "tasks/pushNotificationConfig/set",
    get_push_config: "tasks/pushNotificationConfig/get",
    list_push_configs: "tasks/pushNotificationConfig/list",
    delete_push_config: "tasks/pushNotificationConfig/delete",
    get_agent_card: "agent/card"
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

    payload = %{
      "jsonrpc" => "2.0",
      "id" => env.rpc_id || Utils.new_id(),
      "method" => wire_method_from_envelope(env),
      "params" => params
    }

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
        task_id: get_in(wire, ["params", "id"]) || get_in(wire, ["params", "taskId"]),
        context_id: get_in(wire, ["params", "contextId"]),
        message: get_in(wire, ["params", "message"]),
        payload: wire["params"],
        rpc_id: wire["id"],
        agent_id: get_in(wire, ["params", "agentId"]),
        metadata: get_in(wire, ["params", "metadata"])
      })

    {:ok, env}
  end

  @impl true
  def decode_stream_event(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, other} -> {:ok, other}
      {:error, _} = err -> err
    end
  end

  # -------------------------------------------------------------------
  # Agent Card Functions
  # -------------------------------------------------------------------

  @impl true
  def well_known_path, do: @well_known_path

  @impl true
  def resolve_card_url(agent) do
    case get_in(agent, ["metadata", "agentCard", "url"]) do
      url when is_binary(url) and url != "" -> url
      _ -> "#{agent["url"]}#{@well_known_path}"
    end
  end

  @impl true
  def normalize_agent_card(card) when is_map(card) do
    %{
      "name" => card["name"],
      "url" => card["url"],
      "version" => card["version"] || "1.0.0",
      "protocolVersion" => @protocol_version,
      "description" => card["description"],
      "capabilities" => normalize_capabilities(card["capabilities"]),
      "skills" => normalize_skills(card["skills"]),
      "defaultInputModes" => card["defaultInputModes"] || ["text/plain"],
      "defaultOutputModes" => card["defaultOutputModes"] || ["text/plain"],
      "documentationUrl" => card["documentationUrl"],
      "provider" => card["provider"],
      "securitySchemes" => card["securitySchemes"],
      "security" => card["security"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @impl true
  def valid_card?(card) when is_map(card) do
    is_binary(card["name"]) and card["name"] != ""
  end

  def valid_card?(_), do: false

  # -------------------------------------------------------------------
  # Public Helpers
  # -------------------------------------------------------------------

  @doc "Build A2A JSON-RPC request from envelope for outbound call."
  @spec build_request(Envelope.t()) :: map()
  def build_request(%Envelope{} = env) do
    {:ok, payload} = encode(env)
    payload
  end

  @doc "Parse A2A JSON-RPC response into result or error."
  @spec parse_response(map()) :: {:ok, any()} | {:error, any()}
  def parse_response(%{"result" => result}), do: {:ok, result}
  def parse_response(%{"error" => error}), do: {:error, error}
  def parse_response(other), do: {:error, {:unexpected, other}}

  # -------------------------------------------------------------------
  # Private Helpers
  # -------------------------------------------------------------------

  defp build_params(%Envelope{} = env) do
    %{}
    |> Utils.maybe_put("message", env.message)
    |> Utils.maybe_put("id", env.task_id)
    |> Utils.maybe_put("taskId", env.task_id)
    |> Utils.maybe_put("contextId", env.context_id)
    |> Utils.maybe_put("metadata", env.metadata)
    |> Utils.maybe_put("configuration", get_in_payload(env, "configuration"))
    |> Utils.maybe_put("pushNotificationConfig", get_in_payload(env, "pushNotificationConfig"))
  end

  defp wire_method_from_envelope(%Envelope{method: method}) when is_atom(method) do
    wire_method(method)
  end

  defp wire_method_from_envelope(%Envelope{method: method}) when is_binary(method) do
    # Legacy string method - try to map or pass through
    case method do
      "send" -> wire_method(:send_message)
      "stream" -> wire_method(:stream_message)
      "get" -> wire_method(:get_task)
      "cancel" -> wire_method(:cancel_task)
      "subscribe" -> wire_method(:subscribe_task)
      "list" -> wire_method(:list_tasks)
      other -> other
    end
  end

  defp normalize_capabilities(nil), do: %{}
  defp normalize_capabilities(caps) when is_map(caps), do: caps

  defp normalize_skills(nil), do: []

  defp normalize_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      skill
      |> Map.put_new("tags", [])
      |> Map.put_new("examples", [])
    end)
  end

  defp get_in_payload(%Envelope{payload: nil}, _key), do: nil
  defp get_in_payload(%Envelope{payload: p}, key), do: Map.get(p, key)
end

# Backward compatibility alias - DEPRECATED
defmodule Orchestrator.Protocol.A2A do
  @moduledoc false
  # Delegate to new location
  defdelegate protocol_name(), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate protocol_version(), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate normalize_method(m), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate wire_method(m), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate encode(e), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate decode(w), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate decode_stream_event(d), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate well_known_path(), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate resolve_card_url(a), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate normalize_agent_card(c), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate valid_card?(c), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate build_request(e), to: Orchestrator.Protocol.Adapters.A2A
  defdelegate parse_response(r), to: Orchestrator.Protocol.Adapters.A2A
end
