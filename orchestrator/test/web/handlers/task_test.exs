defmodule Orchestrator.Web.Handlers.TaskTest do
  @moduledoc """
  Tests for Task handlers - tasks.* JSON-RPC methods via Router.
  """
  use Orchestrator.ConnCase, async: false

  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PushConfig

  setup do
    task_id = "task-handler-test-#{:rand.uniform(100_000)}"

    task = %{
      "id" => task_id,
      "status" => %{"state" => "working"},
      "artifacts" => []
    }

    TaskStore.put(task)

    on_exit(fn ->
      TaskStore.delete(task_id)
    end)

    {:ok, task_id: task_id, task: task}
  end

  describe "tasks.get" do
    test "returns task when found", %{task_id: task_id} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        "params" => %{"taskId" => task_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["id"] == task_id
      assert response["result"]["status"]["state"] == "working"
    end

    test "returns error when task not found" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.get",
        "params" => %{"taskId" => "nonexistent-#{:rand.uniform(100_000)}"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32004
      assert response["error"]["message"] =~ "not found"
    end
  end

  describe "tasks.pushNotificationConfig.set" do
    test "returns error for nonexistent task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.pushNotificationConfig.set",
        "params" => %{
          "taskId" => "nonexistent-#{:rand.uniform(100_000)}",
          "config" => %{"url" => "https://example.com"}
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)
      assert response["error"]["code"] == -32004
    end
  end

  describe "tasks.pushNotificationConfig.list" do
    test "lists push configs for task", %{task_id: task_id} do
      # Add some configs first
      PushConfig.set(task_id, %{"url" => "https://example1.com"})
      PushConfig.set(task_id, %{"url" => "https://example2.com"})

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.pushNotificationConfig.list",
        "params" => %{"taskId" => task_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_list(response["result"])
      assert length(response["result"]) >= 2
    end

    test "returns empty list for task with no configs" do
      new_task_id = "no-configs-#{:rand.uniform(100_000)}"
      TaskStore.put(%{"id" => new_task_id, "status" => %{"state" => "working"}})

      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.pushNotificationConfig.list",
        "params" => %{"taskId" => new_task_id}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"] == []

      TaskStore.delete(new_task_id)
    end
  end

  describe "tasks.pushNotificationConfig.delete" do
    test "returns success even if config doesn't exist" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "1",
        "method" => "tasks.pushNotificationConfig.delete",
        "params" => %{"taskId" => "any-task", "configId" => "any-id"}
      }

      conn = json_post("/rpc", request)

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"] == true
    end
  end
end
