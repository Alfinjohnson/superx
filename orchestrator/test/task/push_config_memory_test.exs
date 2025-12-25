defmodule Orchestrator.Task.PushConfig.MemoryTest do
  @moduledoc """
  Tests for Task.PushConfig.Memory - in-memory push config storage.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Task.PushConfig.Memory

  setup do
    task_id = "push-config-test-#{:rand.uniform(100_000)}"
    {:ok, task_id: task_id}
  end

  describe "put/2" do
    test "stores a push config for a task", %{task_id: task_id} do
      config = %{
        "url" => "https://webhook.example.com/notify",
        "token" => "secret-token"
      }

      assert :ok = Memory.put(task_id, config)

      configs = Memory.get_for_task(task_id)
      assert length(configs) == 1

      stored = hd(configs)
      assert stored["task_id"] == task_id
      assert stored["url"] == config["url"]
      assert stored["token"] == config["token"]
    end

    test "stores config with auth header", %{task_id: task_id} do
      config = %{
        "url" => "https://webhook.example.com",
        "authHeader" => "Bearer xyz123"
      }

      Memory.put(task_id, config)

      [stored] = Memory.get_for_task(task_id)
      assert stored["auth_header"] == "Bearer xyz123"
    end

    test "stores config with metadata", %{task_id: task_id} do
      config = %{
        "url" => "https://webhook.example.com",
        "metadata" => %{"source" => "test", "priority" => "high"}
      }

      Memory.put(task_id, config)

      [stored] = Memory.get_for_task(task_id)
      assert stored["metadata"]["source"] == "test"
      assert stored["metadata"]["priority"] == "high"
    end

    test "generates unique IDs for each config", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example1.com"})
      Memory.put(task_id, %{"url" => "https://example2.com"})

      configs = Memory.get_for_task(task_id)
      assert length(configs) == 2

      ids = Enum.map(configs, & &1["id"])
      assert length(Enum.uniq(ids)) == 2
    end

    test "sets inserted_at timestamp", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example.com"})

      [stored] = Memory.get_for_task(task_id)
      assert is_binary(stored["inserted_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(stored["inserted_at"])
    end
  end

  describe "get_for_task/1" do
    test "returns empty list for task with no configs" do
      assert Memory.get_for_task("nonexistent-#{:rand.uniform(100_000)}") == []
    end

    test "returns all configs for a task", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example1.com"})
      Memory.put(task_id, %{"url" => "https://example2.com"})
      Memory.put(task_id, %{"url" => "https://example3.com"})

      configs = Memory.get_for_task(task_id)
      assert length(configs) == 3
    end

    test "only returns configs for specified task", %{task_id: task_id} do
      other_task = "other-task-#{:rand.uniform(100_000)}"

      Memory.put(task_id, %{"url" => "https://mine.com"})
      Memory.put(other_task, %{"url" => "https://theirs.com"})

      configs = Memory.get_for_task(task_id)
      assert length(configs) == 1
      assert hd(configs)["url"] == "https://mine.com"
    end
  end

  describe "get/1" do
    test "returns config by ID", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example.com"})

      [stored] = Memory.get_for_task(task_id)
      config_id = stored["id"]

      fetched = Memory.get(config_id)
      assert fetched["id"] == config_id
      assert fetched["url"] == "https://example.com"
    end

    test "returns nil for nonexistent ID" do
      assert Memory.get("nonexistent-id-#{:rand.uniform(100_000)}") == nil
    end
  end

  describe "delete/1" do
    test "deletes a config by ID", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example.com"})

      [stored] = Memory.get_for_task(task_id)
      config_id = stored["id"]

      assert :ok = Memory.delete(config_id)
      assert Memory.get(config_id) == nil
    end

    test "succeeds for nonexistent ID" do
      assert :ok = Memory.delete("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "delete_for_task/1" do
    test "deletes all configs for a task", %{task_id: task_id} do
      Memory.put(task_id, %{"url" => "https://example1.com"})
      Memory.put(task_id, %{"url" => "https://example2.com"})

      assert length(Memory.get_for_task(task_id)) == 2

      assert :ok = Memory.delete_for_task(task_id)
      assert Memory.get_for_task(task_id) == []
    end

    test "does not affect other tasks", %{task_id: task_id} do
      other_task = "other-task-#{:rand.uniform(100_000)}"

      Memory.put(task_id, %{"url" => "https://mine.com"})
      Memory.put(other_task, %{"url" => "https://theirs.com"})

      Memory.delete_for_task(task_id)

      assert Memory.get_for_task(task_id) == []
      assert length(Memory.get_for_task(other_task)) == 1
    end
  end

  describe "list/0" do
    test "returns all push configs" do
      # Get initial count
      initial = length(Memory.list())

      task1 = "list-test-1-#{:rand.uniform(100_000)}"
      task2 = "list-test-2-#{:rand.uniform(100_000)}"

      Memory.put(task1, %{"url" => "https://example1.com"})
      Memory.put(task2, %{"url" => "https://example2.com"})

      all = Memory.list()
      assert length(all) >= initial + 2
    end
  end
end
