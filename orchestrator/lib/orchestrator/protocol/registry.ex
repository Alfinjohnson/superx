defmodule Orchestrator.Protocol.Registry do
  @moduledoc """
  Protocol adapter registry for dynamic version selection.

  This module maintains a registry of protocol adapters and provides
  functions to select the appropriate adapter based on:
  - Protocol name (a2a, mcp, etc.)
  - Protocol version (0.3.0, 0.4.0, etc.)
  - Agent capabilities

  ## Adding New Protocol Versions

  1. Create adapter module (see A2A_Template)
  2. Add to @adapters map below
  3. Update @latest_versions if it's the newest

  ## Version Negotiation

  When an agent supports multiple versions, the registry can:
  - Select the latest mutually supported version
  - Fall back to older versions for compatibility
  - Reject incompatible version combinations
  """

  require Logger

  # --- Adapter Registry ---
  # Map of {protocol, version} -> adapter module
  # Add new adapters here as they are implemented

  @adapters %{
    {"a2a", "0.3.0"} => Orchestrator.Protocol.Adapters.A2A
    # Future versions:
    # {"a2a", "0.4.0"} => Orchestrator.Protocol.Adapters.A2A_040,
    # {"a2a", "1.0.0"} => Orchestrator.Protocol.Adapters.A2A_100,
    # {"mcp", "1.0.0"} => Orchestrator.Protocol.Adapters.MCP
  }

  # Latest version for each protocol (used when version not specified)
  @latest_versions %{
    "a2a" => "0.3.0"
    # "mcp" => "1.0.0"
  }

  # Ordered versions for negotiation (newest first)
  @version_priority %{
    "a2a" => ["0.3.0"]  # Add newer versions at the front
    # "mcp" => ["1.0.0"]
  }

  @doc """
  Get adapter for specific protocol and version.
  Returns `{:ok, adapter}` or `{:error, reason}`.
  """
  @spec adapter_for(String.t(), String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for(protocol, version) do
    case Map.get(@adapters, {protocol, version}) do
      nil -> {:error, {:unsupported_version, protocol, version}}
      adapter -> {:ok, adapter}
    end
  end

  @doc """
  Get adapter for latest version of a protocol.
  """
  @spec adapter_for_latest(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_latest(protocol) do
    case Map.get(@latest_versions, protocol) do
      nil -> {:error, {:unsupported_protocol, protocol}}
      version -> adapter_for(protocol, version)
    end
  end

  @doc """
  Negotiate best adapter between client and server supported versions.
  Returns the adapter for the highest mutually supported version.

  ## Parameters
  - `protocol` - Protocol name
  - `client_versions` - List of versions client supports
  - `server_versions` - List of versions server supports (optional, defaults to all)
  """
  @spec negotiate(String.t(), [String.t()], [String.t()] | nil) :: {:ok, module(), String.t()} | {:error, term()}
  def negotiate(protocol, client_versions, server_versions \\ nil) do
    server_versions = server_versions || supported_versions(protocol)
    priority = Map.get(@version_priority, protocol, [])

    # Find first (highest priority) version supported by both
    case Enum.find(priority, fn v ->
      v in client_versions and v in server_versions
    end) do
      nil ->
        {:error, {:no_common_version, protocol, client_versions, server_versions}}

      version ->
        case adapter_for(protocol, version) do
          {:ok, adapter} -> {:ok, adapter, version}
          error -> error
        end
    end
  end

  @doc """
  Get all supported versions for a protocol.
  """
  @spec supported_versions(String.t()) :: [String.t()]
  def supported_versions(protocol) do
    @adapters
    |> Map.keys()
    |> Enum.filter(fn {p, _v} -> p == protocol end)
    |> Enum.map(fn {_p, v} -> v end)
  end

  @doc """
  Get all supported protocols.
  """
  @spec supported_protocols() :: [String.t()]
  def supported_protocols do
    @adapters
    |> Map.keys()
    |> Enum.map(fn {p, _v} -> p end)
    |> Enum.uniq()
  end

  @doc """
  Check if a specific protocol/version combination is supported.
  """
  @spec supported?(String.t(), String.t()) :: boolean()
  def supported?(protocol, version) do
    Map.has_key?(@adapters, {protocol, version})
  end

  @doc """
  Get adapter based on agent configuration.
  Uses the agent's declared protocol version if available,
  otherwise falls back to latest.
  """
  @spec adapter_for_agent(map()) :: module()
  def adapter_for_agent(agent_config) do
    protocol = Map.get(agent_config, :protocol, "a2a")
    version = Map.get(agent_config, :protocol_version)

    adapter = if version do
      case adapter_for(protocol, version) do
        {:ok, adapter} -> adapter
        {:error, reason} ->
          Logger.warning("Unsupported protocol version #{protocol}/#{version}: #{inspect(reason)}, falling back to latest")
          adapter_for_latest_or_default(protocol)
      end
    else
      adapter_for_latest_or_default(protocol)
    end

    adapter
  end

  defp adapter_for_latest_or_default(protocol) do
    case adapter_for_latest(protocol) do
      {:ok, adapter} -> adapter
      {:error, _} -> Orchestrator.Protocol.Adapters.A2A  # Default fallback
    end
  end

  @doc """
  List all registered adapters with their protocols and versions.
  Useful for debugging and introspection.
  """
  @spec list_adapters() :: [%{protocol: String.t(), version: String.t(), module: module()}]
  def list_adapters do
    @adapters
    |> Enum.map(fn {{protocol, version}, module} ->
      %{protocol: protocol, version: version, module: module}
    end)
    |> Enum.sort_by(fn %{protocol: p, version: v} -> {p, v} end)
  end
end
