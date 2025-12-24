defmodule Orchestrator.Task.StoreTest do
  @moduledoc """
  Tests for the Task.Store module.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Task.Store

  describe "put/1" do
    test "stores a new task" do
      task = %{
        "id" => "task-#{unique_id()}",
        "contextId" => "ctx-123",
        "status" => %{"state" => "submitted"},
        "artifacts" => [],
        "history" => []
      }

      assert :ok = Store.put(task)

      # Verify it was stored
      stored = Store.get(task["id"])
      assert stored["id"] == task["id"]
      assert stored["status"]["state"] == "submitted"
    end

    test "updates an existing task" do
      task_id = "task-#{unique_id()}"

      task = %{
        "id" => task_id,
        "status" => %{"state" => "submitted"}
      }

      assert :ok = Store.put(task)

      updated = %{
        "id" => task_id,
        "status" => %{"state" => "working"}
      }

      assert :ok = Store.put(updated)

      stored = Store.get(task_id)
      assert stored["status"]["state"] == "working"
    end

    test "rejects task without id" do
      task = %{"status" => %{"state" => "submitted"}}
      assert {:error, :invalid_task} = Store.put(task)
    end

    test "rejects update to terminal task" do
      task_id = "task-#{unique_id()}"

      # Create completed task
      completed = %{
        "id" => task_id,
        "status" => %{"state" => "completed"}
      }

      assert :ok = Store.put(completed)

      # Try to update it
      update = %{
        "id" => task_id,
        "status" => %{"state" => "working"}
      }

      assert {:error, :terminal} = Store.put(update)
    end

    test "rejects update to failed task" do
      task_id = "task-#{unique_id()}"

      failed = %{
        "id" => task_id,
        "status" => %{"state" => "failed"}
      }

      assert :ok = Store.put(failed)

      update = %{"id" => task_id, "status" => %{"state" => "working"}}
      assert {:error, :terminal} = Store.put(update)
    end

    test "rejects update to canceled task" do
      task_id = "task-#{unique_id()}"

      canceled = %{
        "id" => task_id,
        "status" => %{"state" => "canceled"}
      }

      assert :ok = Store.put(canceled)

      update = %{"id" => task_id, "status" => %{"state" => "working"}}
      assert {:error, :terminal} = Store.put(update)
    end
  end

  describe "get/1" do
    test "returns nil for non-existent task" do
      assert Store.get("non-existent-task") == nil
    end

    test "returns task payload for existing task" do
      task_id = "task-#{unique_id()}"

      task = %{
        "id" => task_id,
        "contextId" => "ctx-abc",
        "status" => %{"state" => "working"},
        "metadata" => %{"key" => "value"}
      }

      Store.put(task)
      stored = Store.get(task_id)

      assert stored["id"] == task_id
      assert stored["contextId"] == "ctx-abc"
      assert stored["status"]["state"] == "working"
      assert stored["metadata"]["key"] == "value"
    end
  end

  describe "delete/1" do
    test "deletes existing task" do
      task_id = "task-#{unique_id()}"
      task = %{"id" => task_id, "status" => %{"state" => "completed"}}

      Store.put(task)
      assert Store.get(task_id) != nil

      assert :ok = Store.delete(task_id)
      # Give async replication time to complete
      Process.sleep(10)
      assert Store.get(task_id) == nil
    end

    test "returns :ok for non-existent task" do
      assert :ok = Store.delete("non-existent")
    end
  end

  describe "list/1" do
    test "returns tasks with limit" do
      task1 = %{"id" => "list-1-#{unique_id()}", "status" => %{"state" => "working"}}
      task2 = %{"id" => "list-2-#{unique_id()}", "status" => %{"state" => "completed"}}

      Store.put(task1)
      Store.put(task2)

      tasks = Store.list(limit: 10)
      assert length(tasks) >= 2
    end
  end

  describe "apply_status_update/1" do
    test "updates task status" do
      task_id = "task-#{unique_id()}"
      task = %{"id" => task_id, "status" => %{"state" => "submitted"}}
      Store.put(task)

      update = %{
        "taskId" => task_id,
        "status" => %{"state" => "working", "message" => "Processing..."}
      }

      assert :ok = Store.apply_status_update(update)

      stored = Store.get(task_id)
      assert stored["status"]["state"] == "working"
      assert stored["status"]["message"] == "Processing..."
    end

    test "returns error for non-existent task" do
      update = %{
        "taskId" => "non-existent",
        "status" => %{"state" => "working"}
      }

      assert {:error, :not_found} = Store.apply_status_update(update)
    end

    test "returns error for invalid update" do
      assert {:error, :invalid} = Store.apply_status_update(%{})
      assert {:error, :invalid} = Store.apply_status_update(%{"status" => %{}})
    end
  end

  describe "apply_artifact_update/1" do
    test "adds artifact to task" do
      task_id = "task-#{unique_id()}"

      task = %{
        "id" => task_id,
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      Store.put(task)

      update = %{
        "taskId" => task_id,
        "artifact" => %{
          "name" => "result",
          "parts" => [%{"type" => "text", "text" => "42"}]
        }
      }

      assert :ok = Store.apply_artifact_update(update)

      stored = Store.get(task_id)
      assert length(stored["artifacts"]) == 1
      assert hd(stored["artifacts"])["name"] == "result"
    end

    test "returns error for non-existent task" do
      update = %{
        "taskId" => "non-existent",
        "artifact" => %{"name" => "test"}
      }

      assert {:error, :not_found} = Store.apply_artifact_update(update)
    end
  end

  describe "subscribe/1" do
    test "returns task and subscribes for existing task" do
      task_id = "task-#{unique_id()}"
      task = %{"id" => task_id, "status" => %{"state" => "working"}}
      Store.put(task)

      result = Store.subscribe(task_id)

      assert result["id"] == task_id
      assert result["status"]["state"] == "working"
    end

    test "returns nil for non-existent task" do
      assert Store.subscribe("non-existent") == nil
    end
  end

  # Helper
  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
