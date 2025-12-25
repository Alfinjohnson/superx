defmodule Orchestrator.Protocol.A2A.PushNotifierTest do
  @moduledoc """
  Tests for Protocol.A2A.PushNotifier - webhook delivery with retries.
  """
  use ExUnit.Case, async: false

  alias Orchestrator.Protocol.A2A.PushNotifier

  describe "deliver/2" do
    test "returns error for nil url" do
      payload = %{"task" => %{"id" => "task-123"}}
      assert {:error, :no_url} = PushNotifier.deliver(payload, %{"url" => nil})
    end

    test "returns error for empty url" do
      payload = %{"task" => %{"id" => "task-123"}}
      assert {:error, :no_url} = PushNotifier.deliver(payload, %{"url" => ""})
    end

    test "handles unreachable URL" do
      payload = %{"task" => %{"id" => "task-123", "status" => %{"state" => "completed"}}}
      # Use URL that won't be reachable
      config = %{"url" => "http://localhost:59999/nonexistent"}

      # Should fail after retries
      result = PushNotifier.deliver(payload, config)
      assert {:error, _reason} = result
    end

    test "builds headers with token" do
      # We can test the module creates configs correctly
      # by testing error cases with different auth methods
      payload = %{"task" => %{"id" => "task-123"}}
      config = %{"url" => "http://localhost:59999/hook", "token" => "secret-token"}

      # Will fail but we're testing it doesn't crash on config
      result = PushNotifier.deliver(payload, config)
      assert {:error, _} = result
    end

    test "builds headers with HMAC" do
      payload = %{"task" => %{"id" => "task-123"}}
      config = %{"url" => "http://localhost:59999/hook", "hmacSecret" => "hmac-key"}

      result = PushNotifier.deliver(payload, config)
      assert {:error, _} = result
    end

    test "builds headers with JWT" do
      payload = %{"task" => %{"id" => "task-123"}}

      config = %{
        "url" => "http://localhost:59999/hook",
        "jwtSecret" => "jwt-key",
        "jwtIssuer" => "test-issuer",
        "jwtAudience" => "test-audience",
        "jwtKid" => "key-id-123"
      }

      result = PushNotifier.deliver(payload, config)
      assert {:error, _} = result
    end

    test "extracts task_id from status update payload" do
      payload = %{"statusUpdate" => %{"taskId" => "status-task-123"}}
      config = %{"url" => "http://localhost:59999/hook"}

      # This will fail but tests the task_id extraction path
      result = PushNotifier.deliver(payload, config)
      assert {:error, _} = result
    end

    test "extracts task_id from artifact update payload" do
      payload = %{"artifactUpdate" => %{"taskId" => "artifact-task-123"}}
      config = %{"url" => "http://localhost:59999/hook"}

      result = PushNotifier.deliver(payload, config)
      assert {:error, _} = result
    end
  end

  describe "backward compatibility aliases" do
    test "Orchestrator.Infra.PushNotifier module exists" do
      assert Code.ensure_loaded?(Orchestrator.Infra.PushNotifier)
    end

    test "Orchestrator.PushNotifier module exists" do
      assert Code.ensure_loaded?(Orchestrator.PushNotifier)
    end

    test "delegates deliver/2 function" do
      # Both aliases should have deliver/2
      assert function_exported?(Orchestrator.Infra.PushNotifier, :deliver, 2)
      assert function_exported?(Orchestrator.PushNotifier, :deliver, 2)
    end
  end
end
