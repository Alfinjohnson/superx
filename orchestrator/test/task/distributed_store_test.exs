defmodule Orchestrator.Task.DistributedStoreTest do
  use ExUnit.Case, async: false

  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PubSub, as: TaskPubSub

  describe "hybrid store broadcasts" do
    test "status updates propagate to subscribers" do
      task_id = "task-" <> unique_id()
      task = %{"id" => task_id, "status" => %{"state" => "submitted"}}

      assert :ok = TaskStore.put(task)
      :ok = TaskPubSub.subscribe(task_id)

      update = %{"taskId" => task_id, "status" => %{"state" => "working"}}

      assert :ok = TaskStore.apply_status_update(update)

      assert_receive {:status_update, %{"id" => ^task_id, "status" => %{"state" => "working"}}},
                     200
    end

    test "artifact updates propagate to subscribers" do
      task_id = "task-" <> unique_id()
      task = %{"id" => task_id, "status" => %{"state" => "working"}, "artifacts" => []}

      assert :ok = TaskStore.put(task)
      :ok = TaskPubSub.subscribe(task_id)

      update = %{
        "taskId" => task_id,
        "artifact" => %{"name" => "result", "parts" => [%{"type" => "text", "text" => "ok"}]}
      }

      assert :ok = TaskStore.apply_artifact_update(update)

      assert_receive {:artifact_update, %{"id" => ^task_id, "artifacts" => [artifact]}}, 200
      assert artifact["name"] == "result"
    end
  end

  defp unique_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
