defmodule Orchestrator.Protocol.RegistryTest do
  @moduledoc """
  Tests for Protocol.Registry - adapter registration and lookup.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.Registry

  describe "adapter_for/2" do
    test "returns A2A adapter for a2a 0.3.0" do
      result = Registry.adapter_for("a2a", "0.3.0")

      assert {:ok, Orchestrator.Protocol.Adapters.A2A} = result
    end

    test "returns error for unsupported version" do
      result = Registry.adapter_for("a2a", "999.0.0")

      assert {:error, {:unsupported_version, "a2a", "999.0.0"}} = result
    end
  end

  describe "adapter_for_latest/1" do
    test "returns latest A2A adapter" do
      result = Registry.adapter_for_latest("a2a")

      assert {:ok, Orchestrator.Protocol.Adapters.A2A} = result
    end

    test "returns error for unsupported protocol" do
      result = Registry.adapter_for_latest("unknown_protocol")

      assert {:error, {:unsupported_protocol, "unknown_protocol"}} = result
    end
  end

  describe "negotiate/3" do
    test "selects highest priority mutually supported version" do
      result = Registry.negotiate("a2a", ["0.3.0"], ["0.3.0"])

      assert {:ok, Orchestrator.Protocol.Adapters.A2A, "0.3.0"} = result
    end

    test "returns error when no common version" do
      result = Registry.negotiate("a2a", ["1.0.0"], ["2.0.0"])

      assert {:error, {:no_common_version, "a2a", ["1.0.0"], ["2.0.0"]}} = result
    end

    test "uses all supported versions when server_versions is nil" do
      result = Registry.negotiate("a2a", ["0.3.0"], nil)

      assert {:ok, _, "0.3.0"} = result
    end
  end

  describe "supported_versions/1" do
    test "returns versions for a2a protocol" do
      versions = Registry.supported_versions("a2a")

      assert is_list(versions)
      assert "0.3.0" in versions
    end

    test "returns empty list for unknown protocol" do
      versions = Registry.supported_versions("unknown")

      assert versions == []
    end
  end

  describe "supported_protocols/0" do
    test "returns list of supported protocols" do
      protocols = Registry.supported_protocols()

      assert is_list(protocols)
      assert "a2a" in protocols
    end
  end

  describe "supported?/2" do
    test "returns true for supported combinations" do
      assert Registry.supported?("a2a", "0.3.0") == true
    end

    test "returns false for unsupported combinations" do
      assert Registry.supported?("a2a", "9.9.9") == false
      assert Registry.supported?("unknown", "1.0.0") == false
    end
  end

  describe "adapter_for_agent/1" do
    test "uses agent's declared protocol version" do
      agent = %{protocol: "a2a", protocol_version: "0.3.0"}

      result = Registry.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.A2A
    end

    test "falls back to latest when version not specified" do
      agent = %{protocol: "a2a"}

      result = Registry.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.A2A
    end

    test "defaults to a2a when protocol not specified" do
      agent = %{name: "test"}

      result = Registry.adapter_for_agent(agent)

      assert result == Orchestrator.Protocol.Adapters.A2A
    end

    test "falls back gracefully for unsupported version" do
      agent = %{protocol: "a2a", protocol_version: "999.0.0"}

      result = Registry.adapter_for_agent(agent)

      # Should fall back to latest or default
      assert result == Orchestrator.Protocol.Adapters.A2A
    end
  end

  describe "list_adapters/0" do
    test "returns list of registered adapters" do
      adapters = Registry.list_adapters()

      assert is_list(adapters)
      assert length(adapters) >= 1

      a2a_adapter = Enum.find(adapters, &(&1.protocol == "a2a"))
      assert a2a_adapter.version == "0.3.0"
      assert a2a_adapter.module == Orchestrator.Protocol.Adapters.A2A
    end
  end
end
