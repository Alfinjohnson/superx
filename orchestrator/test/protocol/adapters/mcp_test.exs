defmodule Orchestrator.Protocol.Adapters.MCPTest do
  @moduledoc """
  Tests for MCP Protocol Adapter.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.Adapter, as: MCPAdapter
  alias Orchestrator.Protocol.Envelope

  describe "protocol_name/0" do
    test "returns mcp" do
      assert MCPAdapter.protocol_name() == "mcp"
    end
  end

  describe "protocol_version/0" do
    test "returns correct version" do
      assert MCPAdapter.protocol_version() == "2024-11-05"
    end
  end

  describe "decode/1" do
    test "decodes valid initialize request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        }
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.rpc_id == 1
      assert envelope.method == :initialize
      assert envelope.payload["clientInfo"]["name"] == "test-client"
    end

    test "decodes tools/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.rpc_id == 2
      assert envelope.method == :list_tools
    end

    test "decodes tools/call request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "calculator",
          "arguments" => %{"operation" => "add", "a" => 5, "b" => 3}
        }
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.method == :call_tool
      assert envelope.payload["name"] == "calculator"
    end

    test "decodes resources/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "resources/list"
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.method == :list_resources
    end

    test "decodes prompts/list request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "prompts/list"
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.method == :list_prompts
    end

    test "decodes ping request" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "ping"
      }

      assert {:ok, envelope} = MCPAdapter.decode(request)
      assert envelope.method == :ping
    end
  end

  describe "normalize_method/1" do
    test "normalizes wire method names to canonical atoms" do
      assert MCPAdapter.normalize_method("initialize") == :initialize
      assert MCPAdapter.normalize_method("tools/list") == :list_tools
      assert MCPAdapter.normalize_method("tools/call") == :call_tool
      assert MCPAdapter.normalize_method("resources/list") == :list_resources
      assert MCPAdapter.normalize_method("resources/read") == :read_resource
      assert MCPAdapter.normalize_method("prompts/list") == :list_prompts
      assert MCPAdapter.normalize_method("prompts/get") == :get_prompt
      assert MCPAdapter.normalize_method("ping") == :ping
    end

    test "returns :unknown for unrecognized methods" do
      assert MCPAdapter.normalize_method("unknown/method") == :unknown
    end
  end

  describe "encode/1" do
    test "encodes envelope to wire format" do
      envelope =
        Envelope.new(%{
          protocol: "mcp",
          version: "2024-11-05",
          method: :initialize,
          payload: %{"protocolVersion" => "2024-11-05"},
          rpc_id: 123
        })

      assert {:ok, wire} = MCPAdapter.encode(envelope)

      assert wire["jsonrpc"] == "2.0"
      assert wire["id"] == 123
      assert wire["method"] == "initialize"
      assert wire["params"]["protocolVersion"] == "2024-11-05"
    end

    test "encodes notification without id" do
      envelope =
        Envelope.new(%{
          protocol: "mcp",
          version: "2024-11-05",
          method: :initialized,
          payload: %{}
        })

      assert {:ok, wire} = MCPAdapter.encode(envelope)

      assert wire["jsonrpc"] == "2.0"
      assert wire["method"] == "notifications/initialized"
      refute Map.has_key?(wire, "id")
    end
  end

  describe "wire_method/1" do
    test "converts canonical method to wire format" do
      assert MCPAdapter.wire_method(:initialize) == "initialize"
      assert MCPAdapter.wire_method(:list_tools) == "tools/list"
      assert MCPAdapter.wire_method(:call_tool) == "tools/call"
    end
  end

  describe "decode_stream_event/1" do
    test "decodes SSE result event" do
      data = Jason.encode!(%{"jsonrpc" => "2.0", "result" => %{"status" => "ok"}})

      assert {:ok, {:result, result}} = MCPAdapter.decode_stream_event(data)
      assert result["status"] == "ok"
    end

    test "decodes SSE error event" do
      data =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32600, "message" => "Invalid"}
        })

      assert {:error, error} = MCPAdapter.decode_stream_event(data)
      assert error["code"] == -32600
    end

    test "decodes SSE notification" do
      data =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/message",
          "params" => %{"text" => "hello"}
        })

      assert {:ok, {:notification, :log_message, params}} = MCPAdapter.decode_stream_event(data)
      assert params["text"] == "hello"
    end
  end
end
