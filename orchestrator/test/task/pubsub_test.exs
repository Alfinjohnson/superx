defmodule Orchestrator.Task.PubSubTest do
  @moduledoc """
  Tests for Task.PubSub - subscription and broadcast system.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Task.PubSub

  setup do
    task_id = "pubsub-test-#{:rand.uniform(100_000)}"
    {:ok, task_id: task_id}
  end

  describe "subscribe/1" do
    test "subscribes calling process to task updates", %{task_id: task_id} do
      assert :ok = PubSub.subscribe(task_id)
      assert PubSub.subscriber_count(task_id) >= 1
    end

    test "allows multiple subscriptions to same task", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      # Spawn another process to subscribe
      parent = self()

      spawn(fn ->
        PubSub.subscribe(task_id)
        send(parent, :subscribed)
        Process.sleep(100)
      end)

      assert_receive :subscribed, 1000
      assert PubSub.subscriber_count(task_id) >= 2
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribes calling process from task updates", %{task_id: task_id} do
      PubSub.subscribe(task_id)
      initial_count = PubSub.subscriber_count(task_id)

      assert :ok = PubSub.unsubscribe(task_id)
      assert PubSub.subscriber_count(task_id) < initial_count
    end

    test "is idempotent - unsubscribing when not subscribed works", %{task_id: task_id} do
      assert :ok = PubSub.unsubscribe(task_id)
    end
  end

  describe "broadcast/2" do
    test "broadcasts event to subscribers", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      task = %{"id" => task_id, "status" => %{"state" => "working"}}
      PubSub.broadcast(task_id, {:task_update, task})

      assert_receive {:task_update, ^task}, 1000
    end

    test "broadcasts status updates", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      task = %{"id" => task_id, "status" => %{"state" => "completed"}}
      PubSub.broadcast(task_id, {:status_update, task})

      assert_receive {:status_update, ^task}, 1000
    end

    test "broadcasts artifact updates", %{task_id: task_id} do
      PubSub.subscribe(task_id)

      task = %{"id" => task_id, "artifacts" => [%{"type" => "file"}]}
      PubSub.broadcast(task_id, {:artifact_update, task})

      assert_receive {:artifact_update, ^task}, 1000
    end

    test "does not send to non-subscribers" do
      other_task_id = "other-task-#{:rand.uniform(100_000)}"
      PubSub.subscribe(other_task_id)

      # Broadcast to a different task
      PubSub.broadcast("different-task", {:task_update, %{}})

      refute_receive {:task_update, _}, 100
    end
  end

  describe "subscriber_count/1" do
    test "returns 0 for task with no subscribers" do
      assert PubSub.subscriber_count("no-subscribers-#{:rand.uniform(100_000)}") == 0
    end

    test "returns correct count after subscriptions", %{task_id: task_id} do
      assert PubSub.subscriber_count(task_id) == 0

      PubSub.subscribe(task_id)
      assert PubSub.subscriber_count(task_id) == 1
    end
  end

  describe "process monitoring" do
    test "cleans up subscription when process dies", %{task_id: task_id} do
      parent = self()

      pid =
        spawn(fn ->
          PubSub.subscribe(task_id)
          send(parent, :subscribed)
          Process.sleep(50)
        end)

      assert_receive :subscribed, 1000
      initial_count = PubSub.subscriber_count(task_id)
      assert initial_count >= 1

      # Wait for process to die
      Process.sleep(100)
      refute Process.alive?(pid)

      # Give PubSub time to process DOWN message
      Process.sleep(50)

      # Subscriber should be removed
      assert PubSub.subscriber_count(task_id) < initial_count
    end
  end
end
