defmodule Orchestrator.Protocol.Envelope do
  @moduledoc """
  Internal canonical message envelope for protocol-agnostic processing.

  All inbound/outbound flows translate to/from this structure. The envelope
  uses canonical method atoms (see `Orchestrator.Protocol.Methods`) rather
  than protocol-specific method names.

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `protocol` | string | Protocol name (e.g., "a2a") |
  | `version` | string | Protocol version (e.g., "0.3.0") |
  | `method` | atom/string | Canonical method (e.g., `:send_message`) |
  | `task_id` | string | Task identifier |
  | `context_id` | string | Context for grouping related tasks |
  | `message` | map | Message content |
  | `payload` | map | Full request params |
  | `metadata` | map | Additional metadata |
  | `agent_id` | string | Target agent identifier |
  | `rpc_id` | string | JSON-RPC request ID |

  ## Example

      envelope = Envelope.new(%{
        method: :send_message,
        agent_id: "my-agent",
        message: %{"content" => "Hello"},
        rpc_id: "req-123"
      })
  """

  alias Orchestrator.Protocol.Methods

  @enforce_keys [:method]
  defstruct [
    :protocol,
    :version,
    :method,
    :task_id,
    :context_id,
    :message,
    :payload,
    :metadata,
    :agent_id,
    :rpc_id,
    :webhook
  ]

  @type t :: %__MODULE__{
          protocol: String.t() | nil,
          version: String.t() | nil,
          method: Methods.canonical_method() | String.t(),
          task_id: String.t() | nil,
          context_id: String.t() | nil,
          message: map() | nil,
          payload: map() | nil,
          metadata: map() | nil,
          agent_id: String.t() | nil,
          rpc_id: String.t() | nil,
          webhook: map() | nil
        }

  @doc """
  Build envelope from raw params with defaults.
  Accepts both atom keys and string keys for flexibility.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      protocol: get_attr(attrs, :protocol, "protocol"),
      version: get_attr(attrs, :version, "version"),
      method: normalize_method(get_attr(attrs, :method, "method")),
      task_id: get_attr(attrs, :task_id, "taskId"),
      context_id: get_attr(attrs, :context_id, "contextId"),
      message: get_attr(attrs, :message, "message"),
      payload: get_attr(attrs, :payload, "payload"),
      metadata: get_attr(attrs, :metadata, "metadata"),
      agent_id: get_attr(attrs, :agent_id, "agentId"),
      rpc_id: get_attr(attrs, :rpc_id, "rpcId"),
      webhook: get_attr(attrs, :webhook, "webhook")
    }
  end

  @doc """
  Update envelope fields.
  """
  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = envelope, updates) do
    struct(envelope, updates)
  end

  @doc """
  Check if envelope method is a streaming method.
  """
  @spec streaming?(t()) :: boolean()
  def streaming?(%__MODULE__{method: method}) do
    Methods.streaming?(method)
  end

  # Get attribute with atom key fallback to string key
  defp get_attr(attrs, atom_key, string_key) do
    Map.get(attrs, atom_key) || Map.get(attrs, string_key)
  end

  # Keep atoms as-is, strings are kept for legacy compatibility
  defp normalize_method(method) when is_atom(method), do: method
  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(nil), do: :unknown
end

# Backward compatibility alias - DEPRECATED, use Protocol.Envelope
defmodule Orchestrator.Envelope do
  @moduledoc false
  # Delegate all functions to the new location
  defdelegate new(attrs), to: Orchestrator.Protocol.Envelope
  defdelegate update(envelope, updates), to: Orchestrator.Protocol.Envelope
  defdelegate streaming?(envelope), to: Orchestrator.Protocol.Envelope

  # Re-export struct for pattern matching compatibility
  defstruct Orchestrator.Protocol.Envelope.__struct__()
            |> Map.keys()
            |> Enum.reject(&(&1 == :__struct__))
end
