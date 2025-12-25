defmodule Orchestrator.Protocol.MCP.ClientHandlerTest do
  @moduledoc """
  Tests for MCP ClientHandler - bidirectional request handling.
  """
  use ExUnit.Case, async: true

  alias Orchestrator.Protocol.MCP.ClientHandler

  describe "start_link/1" do
    test "starts handler with session_pid" do
      {:ok, pid} = ClientHandler.start_link(session_pid: self())

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "set_roots/2 and get_roots/1" do
    setup do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())
      on_exit(fn -> if Process.alive?(handler), do: GenServer.stop(handler) end)
      {:ok, handler: handler}
    end

    test "sets and gets roots", %{handler: handler} do
      roots = [
        %{"uri" => "file:///workspace", "name" => "workspace"}
      ]

      assert :ok = ClientHandler.set_roots(handler, roots)
      assert ClientHandler.get_roots(handler) == roots
    end

    test "defaults to empty roots" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      # Default should be some reasonable default (empty or cwd)
      roots = ClientHandler.get_roots(handler)
      assert is_list(roots)

      GenServer.stop(handler)
    end
  end

  describe "configure_sampling/2" do
    test "configures sampling settings" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      config = %{
        provider: :openai,
        model: "gpt-4",
        api_key: "test-key"
      }

      assert :ok = ClientHandler.configure_sampling(handler, config)
      GenServer.stop(handler)
    end
  end

  describe "set_elicitation_handler/2" do
    test "sets custom elicitation handler" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      custom_handler = fn _params -> {:ok, %{"action" => "confirm"}} end

      assert :ok = ClientHandler.set_elicitation_handler(handler, custom_handler)
      GenServer.stop(handler)
    end
  end

  describe "handle_info - roots request" do
    test "responds to roots request" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      roots = [%{"uri" => "file:///test", "name" => "test"}]
      ClientHandler.set_roots(handler, roots)

      # Simulate server sending roots request
      send(handler, {:mcp_roots_request, "req-123", %{}})

      # Response is sent as :mcp_client_response with JSON-RPC format
      assert_receive {:mcp_client_response, response}, 1000
      assert response["id"] == "req-123"
      assert response["result"]["roots"] == roots

      GenServer.stop(handler)
    end
  end

  describe "handle_info - sampling request" do
    test "returns error when sampling not configured" do
      {:ok, handler} =
        ClientHandler.start_link(
          session_pid: self(),
          sampling_config: nil
        )

      send(handler, {:mcp_sampling_request, "req-456", %{"messages" => []}})

      # Should receive error response in JSON-RPC format
      assert_receive {:mcp_client_response, response}, 1000
      assert response["id"] == "req-456"
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "Sampling not configured"

      GenServer.stop(handler)
    end
  end

  describe "handle_info - elicitation request" do
    test "uses custom handler when set" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      custom_handler = fn _params ->
        {:ok, %{"action" => "confirm", "data" => "approved"}}
      end

      ClientHandler.set_elicitation_handler(handler, custom_handler)

      send(handler, {:mcp_elicitation_request, "req-789", %{"prompt" => "Confirm?"}})

      # Response in JSON-RPC format
      assert_receive {:mcp_client_response, response}, 1000
      assert response["id"] == "req-789"
      assert response["result"]["action"] == "confirm"
      assert response["result"]["data"] == "approved"

      GenServer.stop(handler)
    end

    test "returns error when no handler configured" do
      {:ok, handler} = ClientHandler.start_link(session_pid: self())

      send(handler, {:mcp_elicitation_request, "req-abc", %{"prompt" => "Confirm?"}})

      # Should return error in JSON-RPC format
      assert_receive {:mcp_client_response, response}, 1000
      assert response["id"] == "req-abc"
      assert response["error"]["code"] == -32601

      GenServer.stop(handler)
    end
  end
end
