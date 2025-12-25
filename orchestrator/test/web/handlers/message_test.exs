defmodule Orchestrator.Web.Handlers.MessageTest do
  @moduledoc """
  Tests for Web.Handlers.Message - message.send and message.stream handlers.
  """
  use Orchestrator.ConnCase, async: false

  alias Orchestrator.Agent.Store, as: AgentStore

  setup do
    # Create a test agent
    agent_id = "msg-agent-#{:rand.uniform(100_000)}"

    agent = %{
      "id" => agent_id,
      "name" => "Message Test Agent",
      "url" => "http://localhost:9999/a2a",
      "protocol" => "a2a"
    }

    AgentStore.upsert(agent)

    on_exit(fn ->
      AgentStore.delete(agent_id)
    end)

    {:ok, agent_id: agent_id, agent: agent}
  end

  describe "message.send" do
    test "returns error for missing agentId" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.send",
        "params" => %{
          "message" => %{"role" => "user", "parts" => [%{"text" => "Hello"}]}
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      # Error code may be -32004 (no_agent) or -32602 (invalid params)
      assert response["error"]["code"] in [-32004, -32602]
    end

    test "returns error for nonexistent agent" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.send",
        "params" => %{
          "agentId" => "nonexistent-#{:rand.uniform(100_000)}",
          "message" => %{"role" => "user", "parts" => [%{"text" => "Hello"}]}
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      # Could be -32001 (remote error) or other error codes
      assert is_integer(response["error"]["code"])
    end
  end

  describe "message.stream" do
    test "returns error for missing agentId" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.stream",
        "params" => %{
          "message" => %{"role" => "user", "parts" => [%{"text" => "Hello"}]}
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] in [-32004, -32602]
    end

    test "returns error for nonexistent agent" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.stream",
        "params" => %{
          "agentId" => "nonexistent-#{:rand.uniform(100_000)}",
          "message" => %{"role" => "user", "parts" => [%{"text" => "Hello"}]}
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert is_integer(response["error"]["code"])
    end
  end
end
