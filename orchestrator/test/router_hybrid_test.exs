defmodule Orchestrator.RouterHybridTest do
  @moduledoc """
  Router coverage for hybrid (memory) mode.

  Verifies task retrieval over JSON-RPC without relying on Postgres.
  """

  use Orchestrator.ConnCase

  alias Orchestrator.Router
  alias Orchestrator.Task.Store, as: TaskStore

  # Helper to create a POST request with JSON body
  defp json_post(path, body) do
    json_body = Jason.encode!(body)

    :post
    |> conn(path, json_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "tasks.get (hybrid)" do
    test "returns task by id from distributed store" do
      task = %{"id" => "hybrid-task", "status" => %{"state" => "working"}, "artifacts" => []}
      assert :ok = TaskStore.put(task)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        "params" => %{"taskId" => "hybrid-task"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["result"]["id"] == "hybrid-task"
      assert response["result"]["status"]["state"] == "working"
    end

    test "returns error for missing task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        "params" => %{"taskId" => "does-not-exist"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32004
    end
  end

  describe "tasks.subscribe (hybrid)" do
    test "streams updates for existing task" do
      task = %{"id" => "hybrid-sub", "status" => %{"state" => "working"}, "artifacts" => []}
      assert :ok = TaskStore.put(task)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "sub-1",
        "method" => "tasks.subscribe",
        "params" => %{"taskId" => "hybrid-sub"}
      }

      stream_task =
        Task.async(fn ->
          # Ensure the streaming loop terminates even without task updates
          Process.send_after(self(), {:halt, :test}, 100)

          conn = json_post("/rpc", request)

          # Should return chunked SSE response with initial task payload
          assert conn.status == 200
          assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
          assert conn.state == :chunked
          conn
        end)

      assert Task.await(stream_task, 2_000)
    end

    test "returns error for missing task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "sub-missing",
        "method" => "tasks.subscribe",
        "params" => %{"taskId" => "missing"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32004
    end
  end
end
