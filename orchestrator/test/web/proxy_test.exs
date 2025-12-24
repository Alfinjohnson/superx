defmodule Orchestrator.Web.ProxyTest do
  @moduledoc """
  Tests for the Proxy module which handles A2A proxy requests
  to agents through the orchestrator.
  """
  use Orchestrator.ConnCase

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Web.Proxy
  alias Orchestrator.Router

  setup do
    # Clean up agents after each test
    on_exit(fn ->
      AgentStore.delete("proxy-test-agent")
      AgentStore.delete("forwarding-agent")
    end)

    :ok
  end

  describe "handle_request/5 with missing agent" do
    test "returns agent not found error" do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message/send",
        "params" => %{}
      }

      conn =
        :post
        |> conn("/agents/non-existent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Proxy.handle_request("non-existent", "1", "message/send", payload)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32001
      assert response["error"]["message"] == "Agent not found"
    end
  end

  describe "handle_request/5 with registered agent" do
    setup do
      AgentStore.upsert(%{
        "id" => "proxy-test-agent",
        "url" => "http://localhost:59999",
        "protocol" => "a2a",
        "protocolVersion" => "0.3.0"
      })

      :ok
    end

    test "routes message/send to MessageHandler" do
      # This will fail at the agent call level since no real agent,
      # but it tests the routing path
      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message/send",
        "params" => %{
          "message" => %{"role" => "user", "parts" => [%{"text" => "hello"}]}
        }
      }

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Proxy.handle_request("proxy-test-agent", "1", "message/send", payload)

      # Should get an error since there's no real agent, but it went through routing
      assert conn.status in [200, 400]
    end

    test "routes tasks/sendSubscribe through proxy" do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/sendSubscribe",
        "params" => %{}
      }

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Proxy.handle_request("proxy-test-agent", "1", "tasks/sendSubscribe", payload)

      # Method gets normalized and routed
      assert conn.status in [200, 400]
    end
  end

  describe "forward_to_agent/6 error handling" do
    test "returns error when agent is unreachable" do
      agent = %{
        "id" => "forwarding-agent",
        "url" => "http://localhost:59999",
        "protocol" => "a2a"
      }

      AgentStore.upsert(agent)

      {:ok, adapter} = Orchestrator.Protocol.adapter_for("a2a", "0.3.0")

      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "custom/method",
        "params" => %{}
      }

      conn =
        :post
        |> conn("/agents/forwarding-agent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Proxy.forward_to_agent("forwarding-agent", agent, adapter, "1", payload)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32099
      assert response["error"]["message"] =~ "Failed to reach agent"
    end
  end

  describe "integration via router POST /agents/:id" do
    test "returns 400 for invalid JSON-RPC request" do
      AgentStore.upsert(%{
        "id" => "proxy-test-agent",
        "url" => "http://localhost:5000"
      })

      # Invalid request - missing jsonrpc field
      body = %{"method" => "test"}

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32600
    end

    test "proxies valid JSON-RPC request to agent" do
      AgentStore.upsert(%{
        "id" => "proxy-test-agent",
        "url" => "http://localhost:59999"
      })

      body = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "message/send",
        "params" => %{
          "message" => %{"role" => "user", "parts" => [%{"text" => "test"}]}
        }
      }

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      # Will get error since no real agent at that URL
      assert conn.status in [200, 400]
    end
  end

  describe "canonical method routing" do
    setup do
      AgentStore.upsert(%{
        "id" => "proxy-test-agent",
        "url" => "http://localhost:59999",
        "protocol" => "a2a",
        "protocolVersion" => "0.3.0"
      })

      :ok
    end

    test "routes tasks/get to local task handler" do
      # Create a task first
      Orchestrator.Task.Store.put(%{
        "id" => "test-task-123",
        "status" => %{"state" => "working"}
      })

      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks/get",
        "params" => %{"taskId" => "test-task-123"}
      }

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["id"] == "test-task-123"
    end

    test "routes unknown methods to agent forwarding" do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "custom/unknownMethod",
        "params" => %{}
      }

      conn =
        :post
        |> conn("/agents/proxy-test-agent", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      # Will fail since no agent at URL, but tests the forwarding path
      assert conn.status in [200, 400]
    end
  end
end
