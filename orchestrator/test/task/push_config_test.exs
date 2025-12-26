defmodule Orchestrator.Task.PushConfigTest do
  @moduledoc """
  Tests for Task.PushConfig - push notification configuration facade.
  """
  use Orchestrator.DataCase, async: false

  alias Orchestrator.Task.PushConfig
  alias Orchestrator.Task.Store, as: TaskStore

  setup do
    task_id = "push-config-#{:rand.uniform(100_000)}"

    # Create task first (required for FK constraint)
    task = %{
      "id" => task_id,
      "status" => %{"state" => "working"}
    }

    :ok = TaskStore.put(task)

    on_exit(fn ->
      # Clean up configs
      PushConfig.list(task_id)
      |> Enum.each(fn cfg -> PushConfig.delete(task_id, cfg["id"]) end)

      TaskStore.delete(task_id)
    end)

    {:ok, task_id: task_id}
  end

  describe "set/2" do
    test "creates push config for task", %{task_id: task_id} do
      params = %{"url" => "https://webhook.example.com"}

      assert :ok = PushConfig.set(task_id, params)

      configs = PushConfig.list(task_id)
      assert length(configs) >= 1
      assert Enum.any?(configs, fn c -> c["url"] == "https://webhook.example.com" end)
    end

    test "creates config with authentication params", %{task_id: task_id} do
      params = %{
        "url" => "https://webhook.example.com/hook",
        "token" => "secret-token",
        "hmacSecret" => "hmac-secret"
      }

      assert :ok = PushConfig.set(task_id, params)

      configs = PushConfig.list(task_id)
      assert length(configs) >= 1
    end
  end

  describe "list/1" do
    test "returns empty list for task with no configs", %{task_id: _task_id} do
      new_task = "no-configs-#{:rand.uniform(100_000)}"
      assert PushConfig.list(new_task) == []
    end

    test "returns all configs for task", %{task_id: task_id} do
      # Create multiple configs
      :ok = PushConfig.set(task_id, %{"url" => "https://hook1.example.com"})
      :ok = PushConfig.set(task_id, %{"url" => "https://hook2.example.com"})

      configs = PushConfig.list(task_id)
      assert length(configs) >= 2
    end
  end

  describe "get/2" do
    test "returns specific config by id", %{task_id: task_id} do
      :ok = PushConfig.set(task_id, %{"url" => "https://specific.example.com"})

      [config | _] = PushConfig.list(task_id)
      config_id = config["id"]

      result = PushConfig.get(task_id, config_id)
      assert result != nil
      assert result["id"] == config_id
    end

    test "returns nil for nonexistent config" do
      result = PushConfig.get("any-task", "nonexistent-config-id")
      assert result == nil
    end
  end

  describe "delete/2" do
    test "removes config by id", %{task_id: task_id} do
      :ok = PushConfig.set(task_id, %{"url" => "https://delete-me.example.com"})

      [config | _] = PushConfig.list(task_id)
      config_id = config["id"]

      assert :ok = PushConfig.delete(task_id, config_id)

      # Should be gone
      assert PushConfig.get(task_id, config_id) == nil
    end
  end

  describe "deliver_event/3" do
    test "delivers to stored configs", %{task_id: task_id} do
      # Set up a config (delivery will fail since URL doesn't exist, but that's ok)
      :ok = PushConfig.set(task_id, %{"url" => "http://localhost:59999/fake"})

      payload = %{"task" => %{"id" => task_id, "status" => %{"state" => "completed"}}}

      # Should not raise - delivery happens async
      assert :ok = PushConfig.deliver_event(task_id, payload)
    end

    test "delivers to per-request webhook", %{task_id: task_id} do
      payload = %{"task" => %{"id" => task_id}}
      per_request = %{"url" => "http://localhost:59999/per-request"}

      # Should not raise
      assert :ok = PushConfig.deliver_event(task_id, payload, per_request)
    end

    test "handles nil per-request webhook", %{task_id: task_id} do
      payload = %{"task" => %{"id" => task_id}}

      assert :ok = PushConfig.deliver_event(task_id, payload, nil)
    end

    test "returns ok even when no configs exist" do
      payload = %{"task" => %{"id" => "no-configs-task"}}

      assert :ok = PushConfig.deliver_event("no-configs-task", payload)
    end
  end
end
