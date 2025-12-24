defmodule Orchestrator.RouterTest do
  @moduledoc """
  Integration tests for the HTTP Router.

  Note: This router uses HTTP 400 for JSON-RPC errors, not 200 with error body.
  """
  use Orchestrator.ConnCase

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Router

  setup do
    # Reset config
    prev_agents = Application.get_env(:orchestrator, :agents)
    Application.put_env(:orchestrator, :agents, %{})

    on_exit(fn ->
      Application.put_env(:orchestrator, :agents, prev_agents)
    end)

    :ok
  end

  # Helper to create a POST request with JSON body
  defp json_post(path, body) do
    json_body = Jason.encode!(body)

    :post
    |> conn(path, json_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "GET /health" do
    test "returns health status" do
      conn = conn(:get, "/health")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["status"] == "ok"
      assert is_binary(response["node"])
    end
  end

  describe "GET /cluster" do
    test "returns cluster information" do
      conn = conn(:get, "/cluster")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert Map.has_key?(response, "status")
      assert Map.has_key?(response, "load")
    end
  end

  describe "POST /rpc - agents.list" do
    test "returns list of agents" do
      # Create a test agent
      AgentStore.upsert(%{
        "id" => "test-agent",
        "url" => "http://localhost:4001/rpc"
      })

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.list",
        "params" => %{}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "1"
      assert is_list(response["result"])
    end
  end

  describe "POST /rpc - agents.get" do
    test "returns agent by id" do
      AgentStore.upsert(%{
        "id" => "my-agent",
        "url" => "http://localhost:4001/rpc"
      })

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.get",
        "params" => %{"id" => "my-agent"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["result"]["id"] == "my-agent"
      assert response["result"]["url"] == "http://localhost:4001/rpc"
    end

    test "returns error for non-existent agent" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "agents.get",
        "params" => %{"id" => "non-existent"}
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32010
      assert response["error"]["message"] =~ "not found"
    end
  end

  describe "POST /rpc - tasks.get" do
    test "returns task by id" do
      task = %{
        "id" => "task-123",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        # Note: taskId not id
        "params" => %{"taskId" => "task-123"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["result"]["id"] == "task-123"
      assert response["result"]["status"]["state"] == "working"
    end

    test "returns error for non-existent task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        # Note: taskId not id
        "params" => %{"taskId" => "non-existent"}
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      # Task not found
      assert response["error"]["code"] == -32004
    end
  end

  # Note: tasks.list is not implemented in the router
  # The TaskStore.list() exists but no RPC endpoint exposes it

  describe "POST /rpc - invalid request" do
    test "returns error for missing jsonrpc field" do
      request = %{
        "id" => "1",
        "method" => "agents.list"
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32600
      assert response["error"]["message"] =~ "Invalid"
    end

    test "returns error for unknown method" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "unknown.method",
        "params" => %{}
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "not found"
    end
  end

  describe "POST /rpc - message.send" do
    test "returns error when agent not specified" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => "Hello"}]
          }
        }
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "agentId"
    end

    test "returns error when agent not found" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message.send",
        "params" => %{
          "agentId" => "non-existent-agent",
          "message" => %{
            "role" => "user",
            "parts" => [%{"type" => "text", "text" => "Hello"}]
          }
        }
      }

      conn = json_post("/rpc", request)

      # Router returns 400 for errors
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32001
      assert response["error"]["message"] =~ "not found"
    end
  end

  describe "POST /agents/:agent_id - A2A proxy" do
    test "returns error for invalid JSON-RPC request" do
      AgentStore.upsert(%{
        "id" => "proxy-agent",
        "url" => "http://localhost:4001/rpc"
      })

      conn = json_post("/agents/proxy-agent", %{"invalid" => "request"})

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32600
    end
  end

  describe "GET /agents/:agent_id/.well-known/agent-card.json" do
    test "returns 404 for non-existent agent" do
      conn = conn(:get, "/agents/non-existent/.well-known/agent-card.json")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 404
    end
  end

  describe "unknown routes" do
    test "returns 404 for unknown path" do
      conn = conn(:get, "/unknown/path")
      conn = Router.call(conn, Router.init([]))

      assert conn.status == 404
    end
  end
end
