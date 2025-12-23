defmodule Orchestrator.Factory do
  @moduledoc """
  Factory functions for creating test data.
  """

  alias Orchestrator.Repo
  alias Orchestrator.Schema.Task, as: TaskSchema

  # -------------------------------------------------------------------
  # Task Records (for database)
  # -------------------------------------------------------------------

  def build(factory_name, attrs) do
    factory_name
    |> build()
    |> struct!(attrs)
  end

  def build(:task_schema) do
    task_id = "task-#{unique_id()}"

    %TaskSchema{
      id: task_id,
      payload: %{
        "id" => task_id,
        "contextId" => "ctx-#{unique_id()}",
        "status" => %{"state" => "submitted"},
        "artifacts" => [],
        "history" => [],
        "metadata" => %{}
      }
    }
  end

  def build(:completed_task_schema) do
    schema = build(:task_schema)

    payload =
      schema.payload
      |> Map.put("status", %{"state" => "completed"})
      |> Map.put("artifacts", [
        %{
          "name" => "result",
          "parts" => [%{"type" => "text", "text" => "42"}]
        }
      ])

    %{schema | payload: payload}
  end

  # -------------------------------------------------------------------
  # Task Payloads (maps for A2A responses)
  # -------------------------------------------------------------------

  def build(:task_payload) do
    %{
      "id" => "task-#{unique_id()}",
      "contextId" => "ctx-#{unique_id()}",
      "status" => %{"state" => "submitted"},
      "artifacts" => [],
      "history" => [],
      "metadata" => %{}
    }
  end

  def build(:completed_task_payload) do
    build(:task_payload)
    |> Map.merge(%{
      "status" => %{"state" => "completed"},
      "artifacts" => [
        %{
          "name" => "result",
          "parts" => [%{"type" => "text", "text" => "42"}]
        }
      ]
    })
  end

  def build(:working_task_payload) do
    build(:task_payload)
    |> Map.put("status", %{"state" => "working"})
  end

  def build(:failed_task_payload) do
    build(:task_payload)
    |> Map.merge(%{
      "status" => %{"state" => "failed"},
      "metadata" => %{"error" => "Something went wrong"}
    })
  end

  # -------------------------------------------------------------------
  # Agent Configs
  # -------------------------------------------------------------------

  def build(:agent_config) do
    %{
      id: "agent-#{unique_id()}",
      name: "Test Agent",
      url: "http://localhost:4001/rpc",
      protocol: "a2a",
      bearer: nil,
      metadata: %{}
    }
  end

  def build(:agent_config_with_bearer) do
    build(:agent_config)
    |> Map.put(:bearer, "test-bearer-token")
  end

  # -------------------------------------------------------------------
  # A2A Messages
  # -------------------------------------------------------------------

  def build(:a2a_request) do
    %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "method" => "message/send",
      "params" => %{
        "message" => %{
          "role" => "user",
          "parts" => [%{"type" => "text", "text" => "Hello"}]
        }
      }
    }
  end

  def build(:a2a_response) do
    %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "result" => %{
        "id" => "task-#{unique_id()}",
        "contextId" => "ctx-#{unique_id()}",
        "status" => %{
          "state" => "completed"
        },
        "artifacts" => [
          %{
            "name" => "result",
            "parts" => [%{"type" => "text", "text" => "Hello back!"}]
          }
        ]
      }
    }
  end

  def build(:a2a_task_response) do
    %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "result" => %{
        "id" => "task-#{unique_id()}",
        "contextId" => "ctx-#{unique_id()}",
        "status" => %{
          "state" => "working"
        },
        "artifacts" => []
      }
    }
  end

  def build(:a2a_error_response) do
    %{
      "jsonrpc" => "2.0",
      "id" => unique_id(),
      "error" => %{
        "code" => -32601,
        "message" => "Method not found"
      }
    }
  end

  # -------------------------------------------------------------------
  # Agent Cards
  # -------------------------------------------------------------------

  def build(:agent_card) do
    %{
      "name" => "Test Agent",
      "description" => "A test agent for unit tests",
      "url" => "http://localhost:4001/rpc",
      "version" => "1.0.0",
      "capabilities" => %{
        "streaming" => false,
        "pushNotifications" => false
      },
      "skills" => [
        %{
          "id" => "test-skill",
          "name" => "Test Skill",
          "description" => "Does testing"
        }
      ]
    }
  end

  # -------------------------------------------------------------------
  # Push Notification Configs
  # -------------------------------------------------------------------

  def build(:push_config) do
    %{
      "url" => "https://webhook.example.com/push"
    }
  end

  def build(:push_config_with_token) do
    build(:push_config)
    |> Map.put("token", "bearer-token-#{unique_id()}")
  end

  def build(:push_config_with_hmac) do
    build(:push_config)
    |> Map.put("hmacSecret", "hmac-secret-#{unique_id()}")
  end

  def build(:push_config_with_jwt) do
    build(:push_config)
    |> Map.merge(%{
      "jwtSecret" => "jwt-secret-#{unique_id()}",
      "jwtIssuer" => "orchestrator",
      "jwtAudience" => "webhook-receiver",
      "jwtKid" => "key-1"
    })
  end

  def build(:push_config_full) do
    build(:push_config)
    |> Map.merge(%{
      "token" => "bearer-token-#{unique_id()}",
      "hmacSecret" => "hmac-secret-#{unique_id()}",
      "jwtSecret" => "jwt-secret-#{unique_id()}",
      "jwtIssuer" => "orchestrator",
      "jwtAudience" => "webhook-receiver",
      "jwtKid" => "key-1",
      "taskId" => "task-#{unique_id()}"
    })
  end

  # -------------------------------------------------------------------
  # SSE / Streaming Events
  # -------------------------------------------------------------------

  def build(:sse_status_update) do
    %{
      "statusUpdate" => %{
        "taskId" => "task-#{unique_id()}",
        "status" => %{"state" => "working"}
      }
    }
  end

  def build(:sse_artifact_update) do
    %{
      "artifactUpdate" => %{
        "taskId" => "task-#{unique_id()}",
        "artifact" => %{
          "name" => "result",
          "parts" => [%{"type" => "text", "text" => "streaming result"}]
        }
      }
    }
  end

  def build(:sse_task_complete) do
    %{
      "task" => build(:completed_task_payload)
    }
  end

  def build(:sse_message) do
    %{
      "message" => %{
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "Hello from stream"}]
      }
    }
  end

  def build(:sse_event) do
    result = build(:sse_status_update)
    "data: #{Jason.encode!(%{"jsonrpc" => "2.0", "result" => result})}\n\n"
  end

  def build(:sse_event, %{result: result}) do
    "data: #{Jason.encode!(%{"jsonrpc" => "2.0", "result" => result})}\n\n"
  end

  # -------------------------------------------------------------------
  # Stream Payloads (for push notifier)
  # -------------------------------------------------------------------

  def build(:status_update_payload) do
    %{
      "statusUpdate" => %{
        "taskId" => "task-#{unique_id()}",
        "status" => %{"state" => "working", "progress" => 50}
      }
    }
  end

  def build(:artifact_update_payload) do
    %{
      "artifactUpdate" => %{
        "taskId" => "task-#{unique_id()}",
        "artifact" => %{
          "name" => "partial",
          "parts" => [%{"type" => "text", "text" => "in progress"}]
        }
      }
    }
  end

  def build(:task_payload_for_push) do
    %{
      "task" => build(:completed_task_payload)
    }
  end

  # -------------------------------------------------------------------
  # Agent Map (for Worker tests)
  # -------------------------------------------------------------------

  def build(:agent_map) do
    %{
      "id" => "agent-#{unique_id()}",
      "name" => "Test Agent",
      "url" => "http://localhost:4001/rpc",
      "protocol" => "a2a",
      "bearer" => nil,
      "metadata" => %{}
    }
  end

  def build(:agent_map_with_bearer) do
    build(:agent_map)
    |> Map.put("bearer", "test-bearer-token")
  end

  def build(:agent_map_with_config) do
    build(:agent_map)
    |> Map.merge(%{
      "maxInFlight" => 5,
      "failureThreshold" => 3,
      "failureWindowMs" => 10_000,
      "cooldownMs" => 5_000
    })
  end

  # -------------------------------------------------------------------
  # Envelope (for Worker tests)
  # -------------------------------------------------------------------

  def build(:envelope) do
    %Orchestrator.Protocol.Envelope{
      rpc_id: unique_id(),
      method: "message/send",
      task_id: "task-#{unique_id()}",
      context_id: "ctx-#{unique_id()}",
      message: %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "Hello"}]
      },
      payload: %{}
    }
  end

  def build(:stream_envelope) do
    %Orchestrator.Protocol.Envelope{
      rpc_id: unique_id(),
      method: "message/stream",
      task_id: "task-#{unique_id()}",
      context_id: "ctx-#{unique_id()}",
      message: %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "Hello"}]
      },
      payload: %{}
    }
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  def insert!(factory_name, attrs \\ %{}) do
    factory_name
    |> build(attrs)
    |> Repo.insert!()
  end

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
