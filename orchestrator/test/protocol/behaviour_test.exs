defmodule Orchestrator.Protocol.BehaviourTest do
  @moduledoc """
  Tests for Protocol.Behaviour and Protocol facade module.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol
  alias Orchestrator.Protocol.Behaviour

  describe "Behaviour module" do
    test "defines expected callbacks" do
      Code.ensure_loaded!(Behaviour)

      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:protocol_name, 0} in callbacks
      assert {:protocol_version, 0} in callbacks
      assert {:normalize_method, 1} in callbacks
      assert {:wire_method, 1} in callbacks
      assert {:encode, 1} in callbacks
      assert {:decode, 1} in callbacks
      assert {:decode_stream_event, 1} in callbacks
    end

    test "defines optional callbacks" do
      Code.ensure_loaded!(Behaviour)

      optional = Behaviour.behaviour_info(:optional_callbacks)

      assert {:well_known_path, 0} in optional
      assert {:resolve_card_url, 1} in optional
      assert {:normalize_agent_card, 1} in optional
      assert {:valid_card?, 1} in optional
    end
  end

  describe "Protocol.adapter_for/2" do
    test "returns A2A adapter for a2a protocol" do
      result = Protocol.adapter_for("a2a", "0.3.0")

      assert {:ok, adapter} = result
      assert adapter == Orchestrator.Protocol.Adapters.A2A
    end

    test "returns MCP adapter for mcp protocol" do
      result = Protocol.adapter_for("mcp", "2024-11-05")

      assert {:ok, adapter} = result
      assert adapter == Orchestrator.Protocol.Adapters.MCP
    end

    test "defaults to a2a when protocol is nil" do
      result = Protocol.adapter_for(nil, nil)

      assert {:ok, adapter} = result
      assert adapter == Orchestrator.Protocol.Adapters.A2A
    end

    test "returns error for unsupported version" do
      result = Protocol.adapter_for("a2a", "9.9.9")

      assert {:error, {:unsupported_version, "a2a", "9.9.9"}} = result
    end

    test "returns error for unknown protocol" do
      result = Protocol.adapter_for("unknown", "1.0.0")

      # Unknown protocol + version returns unsupported_version error
      assert {:error, {:unsupported_version, "unknown", "1.0.0"}} = result
    end
  end

  describe "Protocol.supported_protocols/0" do
    test "returns list of protocol/version tuples" do
      result = Protocol.supported_protocols()

      assert is_list(result)
      assert {"a2a", "0.3.0"} in result
      assert {"mcp", "2024-11-05"} in result
    end
  end

  describe "Protocol.adapter_for_agent/1" do
    test "returns A2A adapter for A2A agent" do
      # Uses atom keys internally
      agent = %{protocol: "a2a", protocol_version: "0.3.0"}

      result = Protocol.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.A2A
    end

    test "returns MCP adapter for MCP agent" do
      agent = %{protocol: "mcp", protocol_version: "2024-11-05"}

      result = Protocol.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.MCP
    end

    test "defaults to A2A adapter when protocol not specified" do
      agent = %{name: "test"}

      result = Protocol.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.A2A
    end
  end

  describe "Protocol.supported?/2" do
    test "returns true for supported protocols" do
      assert Protocol.supported?("a2a", "0.3.0") == true
      assert Protocol.supported?("mcp", "2024-11-05") == true
    end

    test "returns false for unsupported versions" do
      assert Protocol.supported?("a2a", "9.9.9") == false
      assert Protocol.supported?("unknown", "1.0.0") == false
    end
  end

  describe "Protocol.negotiate_version/3" do
    test "negotiates best version between client and server" do
      result = Protocol.negotiate_version("a2a", ["0.3.0"], ["0.3.0"])

      assert {:ok, _adapter, version} = result
      assert version == "0.3.0"
    end

    test "returns error when no common version" do
      result = Protocol.negotiate_version("a2a", ["1.0.0"], ["2.0.0"])

      assert {:error, {:no_common_version, "a2a", ["1.0.0"], ["2.0.0"]}} = result
    end
  end
end
