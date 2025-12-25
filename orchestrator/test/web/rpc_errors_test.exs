defmodule Orchestrator.Web.RpcErrorsTest do
  @moduledoc """
  Tests for RpcErrors - JSON-RPC error handling.
  """
  use Orchestrator.ConnCase, async: true

  alias Orchestrator.Web.RpcErrors

  describe "code/1" do
    test "returns standard JSON-RPC error codes" do
      assert RpcErrors.code(:parse_error) == -32700
      assert RpcErrors.code(:invalid_request) == -32600
      assert RpcErrors.code(:method_not_found) == -32601
      assert RpcErrors.code(:invalid_params) == -32602
      assert RpcErrors.code(:internal_error) == -32603
    end

    test "returns application-specific error codes" do
      assert RpcErrors.code(:agent_not_found) == -32001
      assert RpcErrors.code(:circuit_open) == -32002
      assert RpcErrors.code(:agent_overloaded) == -32003
      assert RpcErrors.code(:task_not_found) == -32004
      assert RpcErrors.code(:resource_not_found) == -32010
      assert RpcErrors.code(:timeout) == -32098
      assert RpcErrors.code(:remote_error) == -32099
    end
  end

  describe "error_response/4" do
    test "builds basic error response" do
      response = RpcErrors.error_response("req-1", -32600, "Invalid request")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-1"
      assert response["error"]["code"] == -32600
      assert response["error"]["message"] == "Invalid request"
      refute Map.has_key?(response["error"], "data")
    end

    test "builds error response with data" do
      response =
        RpcErrors.error_response("req-2", -32602, "Invalid params", %{"field" => "agentId"})

      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Invalid params"
      assert response["error"]["data"] == %{"field" => "agentId"}
    end

    test "handles nil id" do
      response = RpcErrors.error_response(nil, -32700, "Parse error")

      assert response["id"] == nil
      assert response["error"]["code"] == -32700
    end
  end

  describe "send_error/5" do
    test "sends error response through conn" do
      conn = conn(:post, "/rpc", "")

      result = RpcErrors.send_error(conn, "req-1", -32601, "Method not found")

      assert result.status == 400
      response = Jason.decode!(result.resp_body)
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "Method not found"
    end

    test "sends error response with data" do
      conn = conn(:post, "/rpc", "")

      result =
        RpcErrors.send_error(conn, "req-1", -32602, "Invalid params", %{"details" => "test"})

      response = Jason.decode!(result.resp_body)
      assert response["error"]["data"]["details"] == "test"
    end
  end

  describe "from_internal_error/1" do
    test "maps :no_agent to invalid_params" do
      {code, message} = RpcErrors.from_internal_error({:error, :no_agent})

      assert code == -32602
      assert message =~ "agentId"
    end

    test "maps :agent_missing to agent_not_found" do
      {code, message} = RpcErrors.from_internal_error({:error, :agent_missing})

      assert code == -32001
      assert message =~ "not found"
    end

    test "maps :agent_not_found to agent_not_found" do
      {code, message} = RpcErrors.from_internal_error({:error, :agent_not_found})

      assert code == -32001
      assert message =~ "not found"
    end

    test "maps :circuit_open to circuit_open" do
      {code, message} = RpcErrors.from_internal_error({:error, :circuit_open})

      assert code == -32002
      assert message =~ "circuit breaker"
    end

    test "maps :too_many_requests to agent_overloaded" do
      {code, message} = RpcErrors.from_internal_error({:error, :too_many_requests})

      assert code == -32003
      assert message =~ "overloaded"
    end

    test "maps :task_not_found to task_not_found" do
      {code, message} = RpcErrors.from_internal_error({:error, :task_not_found})

      assert code == -32004
      assert message =~ "not found"
    end

    test "maps :timeout to timeout" do
      {code, message} = RpcErrors.from_internal_error({:error, :timeout})

      assert code == -32098
      assert message =~ "timed out"
    end

    test "maps :decode to parse_error" do
      {code, message} = RpcErrors.from_internal_error({:error, :decode})

      assert code == -32700
      assert message =~ "Invalid JSON"
    end

    test "maps remote error with status" do
      {code, message} = RpcErrors.from_internal_error({:error, {:remote, 500, "Internal error"}})

      assert code == -32099
      assert message =~ "500"
    end

    test "passes through remote JSON-RPC errors" do
      {code, message} =
        RpcErrors.from_internal_error({:error, %{"code" => -32001, "message" => "Custom error"}})

      assert code == -32001
      assert message == "Custom error"
    end

    test "handles unknown errors" do
      {code, message} = RpcErrors.from_internal_error({:error, :something_unexpected})

      assert code == -32099
      assert message =~ "Unknown error"
    end
  end

  describe "handle_error/3" do
    test "sends appropriate error response" do
      conn = conn(:post, "/rpc", "")

      result = RpcErrors.handle_error(conn, "req-1", {:error, :agent_missing})

      assert result.status == 400
      response = Jason.decode!(result.resp_body)
      assert response["error"]["code"] == -32001
    end
  end
end
