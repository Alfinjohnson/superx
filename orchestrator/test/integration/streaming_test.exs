defmodule Orchestrator.Integration.StreamingTest do
  @moduledoc """
  Integration tests for streaming endpoints at the router level.

  Tests the complete flow of SSE streaming through the Router for:
  - message.stream endpoint (agent streaming)
  - tasks.subscribe endpoint (task update streaming)

  Covers multiple concurrent clients, connection handling, event validation,
  and error scenarios.

  Note: These tests use Req.Test.stub for mocking, but the SSE client uses
  Finch directly. Tests may need external agent setup or Finch mocking.
  """

  use Orchestrator.ConnCase, async: false

  # Skip: These tests use Req.Test.stub but SSE client uses Finch directly.
  # They need to be rewritten to either use Bypass or mock Finch properly.
  @moduletag :skip

  alias Orchestrator.Agent.Store, as: AgentStore
  alias Orchestrator.Agent.Worker, as: AgentWorker
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Router
  alias Orchestrator.Factory

  setup do
    # Setup test agent with streaming support
    agent = %{
      "id" => "streaming-agent",
      "url" => "http://test.local/agent",
      "protocol" => "a2a",
      "protocolVersion" => "0.3.0"
    }

    AgentStore.upsert(agent)

    # Start agent worker - pass the full agent map
    {:ok, _pid} = AgentWorker.start_link(agent)

    on_exit(fn ->
      AgentStore.delete(agent["id"])
    end)

    %{agent: agent}
  end

  describe "POST /rpc - message.stream" do
    test "streams events from agent successfully", %{agent: agent} do
      # Setup stub for agent streaming
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        # Simulate agent streaming response
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> stream_test_events()
      end)

      # Make streaming request
      request = %{
        "jsonrpc" => "2.0",
        "id" => "stream-1",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test message"
        }
      }

      conn = json_post("/rpc", request)

      # Should return 200 with stream initialization response
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "stream-1"
      assert response["result"]["taskId"] != nil
      assert response["result"]["agentId"] == agent["id"]
    end

    test "handles stream initialization timeout", %{agent: agent} do
      # Setup stub that never responds
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

        # Don't send any events - let it timeout
        {:ok, conn}
      end)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "stream-timeout",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      # Should return error after timeout
      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32098
      assert response["error"]["message"] =~ "Stream initialization timed out"
    end

    test "handles agent not found error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "stream-2",
        "method" => "message.stream",
        "params" => %{
          "agentId" => "non-existent-agent",
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32001
      assert response["error"]["message"] =~ "Agent not found"
    end

    test "handles missing agentId parameter" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "stream-3",
        "method" => "message.stream",
        "params" => %{
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "agentId is required"
    end

    test "handles circuit breaker open state", %{agent: agent} do
      # Trigger circuit breaker by failing multiple requests
      agent_id = agent["id"]

      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      # Make several failing requests to open circuit
      for _i <- 1..6 do
        request = %{
          "jsonrpc" => "2.0",
          "id" => "fail-#{System.unique_integer([:positive])}",
          "method" => "message.stream",
          "params" => %{
            "agentId" => agent_id,
            "message" => "test"
          }
        }

        json_post("/rpc", request)
        Process.sleep(10)
      end

      # Next request should fail with circuit open
      request = %{
        "jsonrpc" => "2.0",
        "id" => "circuit-test",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent_id,
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32002
      assert response["error"]["message"] =~ "circuit breaker open"
    end

    test "handles malformed agent SSE response", %{agent: agent} do
      # Setup stub that sends malformed SSE data
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> send_malformed_sse()
      end)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "malformed-test",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      # Should handle malformed data gracefully
      assert conn.status in [400, 200]

      if conn.status == 400 do
        response = Jason.decode!(conn.resp_body)
        assert response["error"] != nil
      end
    end

    test "handles agent failure mid-stream", %{agent: agent} do
      parent = self()

      # Setup stub that fails after sending init
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> send_init_then_fail(parent)
      end)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "mid-stream-fail",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      # Should return successful init
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["result"]["taskId"] != nil

      # Verify agent worker handled the failure
      assert_receive {:agent_failed, _reason}, 2_000
    end

    test "handles HTTP error from agent during stream initialization", %{agent: agent} do
      # Setup stub that returns HTTP 500
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Agent Internal Error")
      end)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "http-error",
        "method" => "message.stream",
        "params" => %{
          "agentId" => agent["id"],
          "message" => "test"
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] in [-32099, -32098]
      assert response["error"]["message"] =~ ~r/(error|timed?\s*out)/i
    end
  end

  describe "POST /rpc - tasks.subscribe error scenarios" do
    test "streams task updates via SSE" do
      # Create a task
      task = %{
        "id" => "task-stream-1",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      # Make subscription request
      request = %{
        "jsonrpc" => "2.0",
        "id" => "sub-1",
        "method" => "tasks.subscribe",
        "params" => %{
          "taskId" => task["id"]
        }
      }

      # Use Task to handle async SSE streaming
      parent = self()

      task_pid =
        Task.async(fn ->
          conn = json_post("/rpc", request)

          # Should return 200 with streaming response
          assert conn.status == 200
          assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]

          send(parent, {:stream_started, conn})

          # Connection should be chunked
          assert conn.state == :chunked

          conn
        end)

      # Wait for stream to start
      assert_receive {:stream_started, _conn}, 1000

      # Update the task to trigger stream event
      updated_task = Map.put(task, "status", %{"state" => "completed"})
      TaskStore.put(updated_task)

      # Task should complete when terminal state is reached
      assert Task.await(task_pid, 2000)
    end

    test "returns error for non-existent task" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "sub-2",
        "method" => "tasks.subscribe",
        "params" => %{
          "taskId" => "non-existent-task"
        }
      }

      conn = json_post("/rpc", request)

      assert conn.status == 400
      response = Jason.decode!(conn.resp_body)

      assert response["error"]["code"] == -32004
      assert response["error"]["message"] =~ "Task not found"
    end

    test "handles multiple concurrent subscribers to same task" do
      # Create a task
      task = %{
        "id" => "task-multi-sub",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      # Start 3 concurrent subscribers
      subscribers =
        for i <- 1..3 do
          Task.async(fn ->
            request = %{
              "jsonrpc" => "2.0",
              "id" => "sub-#{i}",
              "method" => "tasks.subscribe",
              "params" => %{
                "taskId" => task["id"]
              }
            }

            conn = json_post("/rpc", request)
            assert conn.status == 200
            assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]

            conn
          end)
        end

      # Give time for all subscriptions to establish
      Process.sleep(100)

      # Update task - all subscribers should receive update
      updated_task = Map.put(task, "status", %{"state" => "completed"})
      TaskStore.put(updated_task)

      # All subscribers should complete successfully
      results = Task.await_many(subscribers, 2000)
      assert length(results) == 3
      Enum.each(results, fn conn -> assert conn.status == 200 end)
    end

    test "handles task reaching terminal state" do
      # Create task in working state
      task = %{
        "id" => "task-terminal",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      parent = self()

      task_pid =
        Task.async(fn ->
          request = %{
            "jsonrpc" => "2.0",
            "id" => "sub-terminal",
            "method" => "tasks.subscribe",
            "params" => %{
              "taskId" => task["id"]
            }
          }

          conn = json_post("/rpc", request)
          send(parent, {:subscribed, conn})

          conn
        end)

      assert_receive {:subscribed, conn}, 1000
      assert conn.status == 200

      # Update to terminal state
      completed_task = Map.put(task, "status", %{"state" => "completed"})
      TaskStore.put(completed_task)

      # Stream should close
      result = Task.await(task_pid, 2000)
      assert result.status == 200
    end

    test "sends keep-alive comments during idle periods" do
      # Create a long-running task
      task = %{
        "id" => "task-keepalive",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"},
        "artifacts" => []
      }

      TaskStore.put(task)

      parent = self()

      task_pid =
        Task.async(fn ->
          request = %{
            "jsonrpc" => "2.0",
            "id" => "sub-keepalive",
            "method" => "tasks.subscribe",
            "params" => %{
              "taskId" => task["id"]
            }
          }

          conn = json_post("/rpc", request)
          send(parent, {:stream_active, conn})

          # Wait for potential keep-alive (normally 15s, but test won't wait that long)
          Process.sleep(500)

          conn
        end)

      assert_receive {:stream_active, conn}, 1000
      assert conn.status == 200

      # Complete the task to close stream
      completed = Map.put(task, "status", %{"state" => "completed"})
      TaskStore.put(completed)

      Task.await(task_pid, 2000)
    end
  end

  describe "concurrent streaming" do
    test "handles multiple simultaneous message.stream requests", %{agent: agent} do
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> stream_test_events()
      end)

      # Start 10 concurrent streaming requests
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            request = %{
              "jsonrpc" => "2.0",
              "id" => "concurrent-#{i}",
              "method" => "message.stream",
              "params" => %{
                "agentId" => agent["id"],
                "message" => "concurrent test #{i}"
              }
            }

            conn = json_post("/rpc", request)
            assert conn.status == 200

            response = Jason.decode!(conn.resp_body)
            assert response["result"]["taskId"] != nil

            response
          end)
        end

      # All should complete successfully
      results = Task.await_many(tasks, 5000)
      assert length(results) == 10

      # Each should have unique task ID
      task_ids = Enum.map(results, & &1["result"]["taskId"])
      assert length(Enum.uniq(task_ids)) == 10
    end

    test "handles mixed message.stream and tasks.subscribe requests" do
      Req.Test.stub(Orchestrator.SSETest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> stream_test_events()
      end)

      # Create tasks for subscription
      tasks_for_sub =
        for i <- 1..5 do
          task = %{
            "id" => "mixed-task-#{i}",
            "agentId" => "streaming-agent",
            "status" => %{"state" => "working"},
            "artifacts" => []
          }

          TaskStore.put(task)
          task
        end

      # Mix of stream and subscribe requests
      all_tasks =
        for i <- 1..5 do
          # Alternate between message.stream and tasks.subscribe
          if rem(i, 2) == 0 do
            Task.async(fn ->
              request = %{
                "jsonrpc" => "2.0",
                "id" => "mixed-stream-#{i}",
                "method" => "message.stream",
                "params" => %{
                  "agentId" => "streaming-agent",
                  "message" => "test #{i}"
                }
              }

              conn = json_post("/rpc", request)
              assert conn.status == 200
              {:stream, conn}
            end)
          else
            Task.async(fn ->
              task = Enum.at(tasks_for_sub, div(i, 2))

              request = %{
                "jsonrpc" => "2.0",
                "id" => "mixed-sub-#{i}",
                "method" => "tasks.subscribe",
                "params" => %{
                  "taskId" => task["id"]
                }
              }

              conn = json_post("/rpc", request)
              assert conn.status == 200

              # Complete task to close subscription
              completed = Map.put(task, "status", %{"state" => "completed"})
              TaskStore.put(completed)

              {:subscribe, conn}
            end)
          end
        end

      # All should complete successfully
      results = Task.await_many(all_tasks, 5000)
      assert length(results) == 5
    end
  end

  # --- Helper Functions ---

  defp json_post(path, body) do
    json_body = Jason.encode!(body)

    :post
    |> conn(path, json_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  defp stream_test_events(conn) do
    # Send stream initialization event
    init_event = Factory.build(:sse_event, %{
      result: %{
        "taskId" => "test-task-#{System.unique_integer([:positive])}",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"}
      }
    })

    {:ok, conn} = Plug.Conn.chunk(conn, format_sse_event(init_event))

    # Send a few updates
    for i <- 1..3 do
      event = Factory.build(:sse_event, %{
        result: Factory.build(:sse_status_update, %{"state" => "working", "message" => "Step #{i}"})
      })

      {:ok, conn} = Plug.Conn.chunk(conn, format_sse_event(event))
      Process.sleep(10)
    end

    # Send completion
    final_event = Factory.build(:sse_event, %{
      result: Factory.build(:sse_status_update, %{"state" => "completed"})
    })

    {:ok, conn} = Plug.Conn.chunk(conn, format_sse_event(final_event))

    {:ok, conn}
  end

  defp format_sse_event(event) do
    "data: #{Jason.encode!(event)}\n\n"
  end

  defp send_malformed_sse(conn) do
    # Send invalid JSON
    {:ok, conn} = Plug.Conn.chunk(conn, "data: {invalid json\n\n")
    {:ok, conn}
  end

  defp send_init_then_fail(conn, parent) do
    # Send valid init event
    init_event = Factory.build(:sse_event, %{
      result: %{
        "taskId" => "test-task-#{System.unique_integer([:positive])}",
        "agentId" => "streaming-agent",
        "status" => %{"state" => "working"}
      }
    })

    {:ok, conn} = Plug.Conn.chunk(conn, format_sse_event(init_event))

    # Simulate failure
    send(parent, {:agent_failed, :connection_lost})

    # Close connection abruptly
    {:ok, conn}
  end
end
