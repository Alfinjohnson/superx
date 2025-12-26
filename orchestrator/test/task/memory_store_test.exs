defmodule Orchestrator.Task.Store.FacadeTest do
  @moduledoc """
  Tests for task storage via Task.Store (uses underlying memory/distributed store).
  """
  use ExUnit.Case, async: false
  @moduletag :skip

  alias Orchestrator.Task.Store

  setup do
    # Clean up task after test
    task_id = "test-task-#{:rand.uniform(100_000)}"
    on_exit(fn -> Store.delete(task_id) end)

    {:ok, task_id: task_id}
  end

  describe "put/1 and get/1" do
    test "stores and retrieves a task", %{task_id: task_id} do
      task = %{
        "id" => task_id,
        "status" => %{"state" => "submitted"},
        "history" => []
      }

      assert :ok = Store.put(task)
      assert retrieved = Store.get(task_id)
      assert retrieved["id"] == task_id
      assert retrieved["status"]["state"] == "submitted"
    end

    test "returns nil for non-existent task" do
      result = Store.get("nonexistent-task-#{:rand.uniform(100_000)}")
      assert result == nil
    end
  end

  describe "delete/1" do
    test "deletes a task" do
      task_id = "delete-test-#{System.unique_integer([:positive])}"
      task = %{"id" => task_id, "status" => %{"state" => "working"}}
      :ok = Store.put(task)
      Process.sleep(20)

      assert :ok = Store.delete(task_id)
      Process.sleep(10)
      assert Store.get(task_id) == nil
    end

    test "succeeds even for non-existent task" do
      assert :ok = Store.delete("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "list/0" do
    test "returns list of tasks" do
      tasks = Store.list()
      assert is_list(tasks)
    end
  end

  describe "subscribe/1" do
    test "returns task when it exists", %{task_id: task_id} do
      task = %{"id" => task_id, "status" => %{"state" => "working"}}
      Store.put(task)

      result = Store.subscribe(task_id)
      assert result["id"] == task_id
    end

    test "returns nil when task doesn't exist" do
      result = Store.subscribe("nonexistent-#{:rand.uniform(100_000)}")
      assert result == nil
    end
  end
end
