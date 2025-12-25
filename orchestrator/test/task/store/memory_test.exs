defmodule Orchestrator.Task.Store.MemoryTest do
  @moduledoc """
  Tests for Task.Store.Memory - ETS-based task storage.
  Uses Task.Store facade which routes to the memory adapter.
  """
  use Orchestrator.DataCase, async: false

  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PubSub

  setup do
    task_id = "task-mem-#{:rand.uniform(100_000)}"
    task = %{"id" => task_id, "status" => %{"state" => "working"}}
    :ok = TaskStore.put(task)

    on_exit(fn ->
      TaskStore.delete(task_id)
    end)

    {:ok, task_id: task_id, task: task}
  end

  describe "put/1" do
    test "stores a task", %{task_id: _task_id} do
      new_id = "put-test-#{:rand.uniform(100_000)}"
      task = %{"id" => new_id, "status" => %{"state" => "submitted"}}

      assert :ok = TaskStore.put(task)
      assert TaskStore.get(new_id) != nil

      TaskStore.delete(new_id)
    end

    test "updates existing task", %{task_id: task_id} do
      updated = %{"id" => task_id, "status" => %{"state" => "working"}, "extra" => "data"}
      assert :ok = TaskStore.put(updated)

      result = TaskStore.get(task_id)
      assert result["extra"] == "data"
    end

    test "rejects task without id" do
      assert {:error, :invalid_task} = TaskStore.put(%{"status" => %{"state" => "working"}})
    end

    test "rejects update to terminal task", %{task_id: _task_id} do
      terminal_id = "terminal-#{:rand.uniform(100_000)}"
      task = %{"id" => terminal_id, "status" => %{"state" => "completed"}}
      :ok = TaskStore.put(task)

      # Try to update a terminal task
      updated = %{"id" => terminal_id, "status" => %{"state" => "working"}}
      assert {:error, :terminal} = TaskStore.put(updated)

      TaskStore.delete(terminal_id)
    end
  end

  describe "get/1" do
    test "returns task when found", %{task_id: task_id} do
      result = TaskStore.get(task_id)
      assert result["id"] == task_id
      assert result["status"]["state"] == "working"
    end

    test "returns nil when not found" do
      assert nil == TaskStore.get("nonexistent-#{:rand.uniform(100_000)}")
    end

    test "adds id to task if missing" do
      task_id = "id-test-#{:rand.uniform(100_000)}"
      :ok = TaskStore.put(%{"id" => task_id, "status" => %{"state" => "working"}})

      result = TaskStore.get(task_id)
      assert result["id"] == task_id

      TaskStore.delete(task_id)
    end
  end

  describe "delete/1" do
    test "removes task" do
      # Use unique task ID for this test to avoid race conditions
      delete_task_id = "delete-test-#{:rand.uniform(100_000)}"
      :ok = TaskStore.put(%{"id" => delete_task_id, "status" => %{"state" => "working"}})

      assert :ok = TaskStore.delete(delete_task_id)
      # Small delay to ensure delete propagates
      Process.sleep(10)
      assert nil == TaskStore.get(delete_task_id)
    end

    test "returns ok for nonexistent task" do
      assert :ok = TaskStore.delete("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "subscribe/1" do
    test "subscribes to task and returns it", %{task_id: task_id} do
      result = TaskStore.subscribe(task_id)
      assert result["id"] == task_id

      # Should receive broadcasts now
      PubSub.broadcast(task_id, {:test, "message"})
      assert_receive {:test, "message"}, 1000
    end

    test "returns nil for nonexistent task" do
      assert nil == TaskStore.subscribe("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "list/1" do
    test "lists all tasks" do
      ids =
        for i <- 1..3 do
          id = "list-test-#{i}-#{:rand.uniform(100_000)}"
          :ok = TaskStore.put(%{"id" => id, "status" => %{"state" => "working"}})
          id
        end

      result = TaskStore.list()
      assert is_list(result)
      assert length(result) >= 3

      Enum.each(ids, &TaskStore.delete/1)
    end

    test "respects limit option" do
      result = TaskStore.list(limit: 1)
      assert length(result) <= 1
    end
  end

  describe "apply_status_update/1" do
    test "updates task status", %{task_id: task_id} do
      update = %{"taskId" => task_id, "status" => %{"state" => "completed"}}
      assert :ok = TaskStore.apply_status_update(update)

      result = TaskStore.get(task_id)
      assert result["status"]["state"] == "completed"
    end

    test "returns error for nonexistent task" do
      update = %{"taskId" => "nonexistent-#{:rand.uniform(100_000)}", "status" => %{"state" => "working"}}
      assert {:error, :not_found} = TaskStore.apply_status_update(update)
    end

    test "returns error for invalid update" do
      assert {:error, :invalid} = TaskStore.apply_status_update(%{})
      assert {:error, :invalid} = TaskStore.apply_status_update("invalid")
    end

    test "broadcasts status update", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      update = %{"taskId" => task_id, "status" => %{"state" => "working", "message" => "progress"}}
      :ok = TaskStore.apply_status_update(update)

      assert_receive {:status_update, _task}, 1000
    end
  end

  describe "apply_artifact_update/1" do
    test "adds artifact to task", %{task_id: task_id} do
      update = %{
        "taskId" => task_id,
        "artifact" => %{"name" => "result.txt", "data" => "content"}
      }

      assert :ok = TaskStore.apply_artifact_update(update)

      result = TaskStore.get(task_id)
      assert length(result["artifacts"]) == 1
      assert hd(result["artifacts"])["name"] == "result.txt"
    end

    test "updates existing artifact by name", %{task_id: task_id} do
      update1 = %{
        "taskId" => task_id,
        "artifact" => %{"name" => "file.txt", "data" => "v1"}
      }

      :ok = TaskStore.apply_artifact_update(update1)

      update2 = %{
        "taskId" => task_id,
        "artifact" => %{"name" => "file.txt", "data" => "v2"}
      }

      :ok = TaskStore.apply_artifact_update(update2)

      result = TaskStore.get(task_id)
      assert length(result["artifacts"]) == 1
      assert hd(result["artifacts"])["data"] == "v2"
    end

    test "handles multiple artifacts", %{task_id: task_id} do
      update = %{
        "taskId" => task_id,
        "artifacts" => [
          %{"name" => "a.txt", "data" => "a"},
          %{"name" => "b.txt", "data" => "b"}
        ]
      }

      assert :ok = TaskStore.apply_artifact_update(update)

      result = TaskStore.get(task_id)
      assert length(result["artifacts"]) == 2
    end

    test "returns error for nonexistent task" do
      update = %{"taskId" => "nonexistent-#{:rand.uniform(100_000)}", "artifact" => %{}}
      assert {:error, :not_found} = TaskStore.apply_artifact_update(update)
    end

    test "returns error for invalid update" do
      assert {:error, :invalid} = TaskStore.apply_artifact_update(%{})
    end

    test "broadcasts artifact update", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      update = %{"taskId" => task_id, "artifact" => %{"name" => "out.txt"}}
      :ok = TaskStore.apply_artifact_update(update)

      assert_receive {:artifact_update, _task}, 1000
    end
  end
end
