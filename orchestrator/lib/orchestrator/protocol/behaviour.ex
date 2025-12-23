defmodule Orchestrator.Protocol.Behaviour do
  @moduledoc """
  Behaviour definition for protocol adapters.

  Each adapter translates between internal `Protocol.Envelope` and wire format
  for a specific protocol version. This abstraction allows supporting multiple
  A2A versions and potentially other protocols (MCP, etc.) in the future.

  ## Implementing a New Protocol Version

  1. Create a new adapter module in `protocol/adapters/`
  2. Add `@behaviour Orchestrator.Protocol.Behaviour`
  3. Implement all required callbacks
  4. Register in `Protocol.Registry`

  ## Canonical vs Wire Methods

  The orchestrator uses canonical method atoms internally (see `Protocol.Methods`).
  Adapters translate between:

  - **Wire method names**: Protocol-specific (e.g., "SendMessage" for A2A 0.3.0)
  - **Canonical method atoms**: Internal (e.g., `:send_message`)

  ## Example Adapter

      defmodule MyProtocol.Adapter do
        @behaviour Orchestrator.Protocol.Behaviour

        @impl true
        def protocol_name, do: "my_protocol"

        @impl true
        def protocol_version, do: "1.0.0"

        @impl true
        def normalize_method("DoSomething"), do: :do_something
        def normalize_method(_), do: :unknown

        # ... implement other callbacks
      end
  """

  alias Orchestrator.Protocol.Envelope
  alias Orchestrator.Protocol.Methods

  # -------------------------------------------------------------------
  # Required Callbacks - Core
  # -------------------------------------------------------------------

  @doc "Returns the protocol name (e.g., 'a2a', 'mcp')."
  @callback protocol_name() :: String.t()

  @doc "Returns the protocol version (e.g., '0.3.0')."
  @callback protocol_version() :: String.t()

  # -------------------------------------------------------------------
  # Required Callbacks - Method Mapping
  # -------------------------------------------------------------------

  @doc """
  Convert wire method name to canonical method atom.
  Returns `:unknown` for unrecognized methods.
  """
  @callback normalize_method(String.t()) :: Methods.canonical_method()

  @doc "Convert canonical method atom to wire method name."
  @callback wire_method(Methods.canonical_method()) :: String.t()

  # -------------------------------------------------------------------
  # Required Callbacks - Encoding/Decoding
  # -------------------------------------------------------------------

  @doc "Encode an internal envelope to wire format (map/JSON-ready)."
  @callback encode(Envelope.t()) :: {:ok, map()} | {:error, term()}

  @doc "Decode wire format to internal envelope."
  @callback decode(map()) :: {:ok, Envelope.t()} | {:error, term()}

  @doc "Parse a streaming event (SSE data) into envelope or update."
  @callback decode_stream_event(String.t()) :: {:ok, Envelope.t() | map()} | {:error, term()}

  # -------------------------------------------------------------------
  # Optional Callbacks - Agent Card
  # -------------------------------------------------------------------

  @doc "Returns the well-known path for agent card discovery."
  @callback well_known_path() :: String.t()

  @doc "Resolve agent card URL from agent config (explicit URL or fallback to well-known)."
  @callback resolve_card_url(map()) :: String.t()

  @doc "Normalize agent card to protocol-specific structure."
  @callback normalize_agent_card(map()) :: map()

  @doc "Validate agent card has required fields for the protocol."
  @callback valid_card?(map()) :: boolean()

  @optional_callbacks [
    well_known_path: 0,
    resolve_card_url: 1,
    normalize_agent_card: 1,
    valid_card?: 1
  ]
end

# Backward compatibility - re-export behaviour from original location
defmodule Orchestrator.Protocol do
  @moduledoc """
  Protocol adapter facade.

  This module provides a unified interface for working with protocol adapters.
  For the behaviour definition, see `Orchestrator.Protocol.Behaviour`.

  ## Usage

      # Get adapter for a protocol/version
      {:ok, adapter} = Protocol.adapter_for("a2a", "0.3.0")

      # Get adapter for an agent
      adapter = Protocol.adapter_for_agent(agent)

      # List supported protocols
      Protocol.supported_protocols()
  """

  alias Orchestrator.Protocol.Registry

  # Re-export behaviour callbacks for backward compatibility
  @callback encode(Orchestrator.Protocol.Envelope.t()) :: {:ok, map()} | {:error, term()}
  @callback decode(map()) :: {:ok, Orchestrator.Protocol.Envelope.t()} | {:error, term()}
  @callback decode_stream_event(String.t()) :: {:ok, any()} | {:error, term()}
  @callback normalize_method(String.t()) :: Orchestrator.Protocol.Methods.canonical_method()
  @callback wire_method(Orchestrator.Protocol.Methods.canonical_method()) :: String.t()
  @callback well_known_path() :: String.t()
  @callback resolve_card_url(map()) :: String.t()
  @callback normalize_agent_card(map()) :: map()
  @callback valid_card?(map()) :: boolean()
  @callback protocol_name() :: String.t()
  @callback protocol_version() :: String.t()

  @optional_callbacks [
    well_known_path: 0,
    resolve_card_url: 1,
    normalize_agent_card: 1,
    valid_card?: 1
  ]

  # -------------------------------------------------------------------
  # Registry Delegation
  # -------------------------------------------------------------------

  @doc """
  Get adapter module for protocol/version combination.

  ## Examples

      iex> Protocol.adapter_for("a2a", "0.3.0")
      {:ok, Orchestrator.Protocol.Adapters.A2A}

      iex> Protocol.adapter_for("a2a", "0.4.0")
      {:error, {:unsupported_version, "a2a", "0.4.0"}}
  """
  @spec adapter_for(String.t() | nil, String.t() | nil) :: {:ok, module()} | {:error, term()}
  def adapter_for(nil, _version), do: Registry.adapter_for_latest("a2a")
  def adapter_for(protocol, nil), do: Registry.adapter_for_latest(protocol)
  def adapter_for(protocol, version), do: Registry.adapter_for(protocol, version)

  @doc "List all supported protocol/version combinations."
  @spec supported_protocols() :: [{String.t(), String.t()}]
  def supported_protocols do
    Registry.list_adapters()
    |> Enum.map(fn %{protocol: p, version: v} -> {p, v} end)
  end

  @doc "Get adapter for an agent configuration."
  @spec adapter_for_agent(map()) :: module()
  def adapter_for_agent(agent), do: Registry.adapter_for_agent(agent)

  @doc "Negotiate best protocol version between client and server."
  @spec negotiate_version(String.t(), [String.t()], [String.t()] | nil) ::
          {:ok, module(), String.t()} | {:error, term()}
  defdelegate negotiate_version(protocol, client_versions, server_versions \\ nil),
    to: Registry,
    as: :negotiate

  @doc "Check if a protocol/version is supported."
  @spec supported?(String.t(), String.t()) :: boolean()
  defdelegate supported?(protocol, version), to: Registry
end
