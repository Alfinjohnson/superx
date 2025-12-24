defmodule Orchestrator.Integration.SSEStreamingTest do
  @moduledoc """
  Integration tests for SSE streaming client using a real HTTP server.

  These tests spin up an actual Plug/Cowboy server to verify the SSE client
  handles real HTTP connections, streaming responses, and error conditions.
  """

  use ExUnit.Case, async: false

  alias Orchestrator.Infra.SSEClient
  alias Orchestrator.Task.Store, as: TaskStore

  @moduletag :integration

  # Test server configuration
  @test_port 54321

  setup do
    # Start a test HTTP server for SSE
    {:ok, pid} = start_test_server()

    on_exit(fn ->
      stop_test_server(pid)
    end)

    :ok
  end

  describe "SSE client integration" do
    test "receives stream_init on successful connection" do
      task_id = unique_id()
      rpc_id = "rpc-#{unique_id()}"

      # Start SSE client pointing to test server
      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/success",
          payload: %{
            "jsonrpc" => "2.0",
            "method" => "message/stream",
            "params" => %{"taskId" => task_id}
          },
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      # Should receive stream_init with status update
      assert_receive {:stream_init, ^rpc_id, result}, 5000
      assert result["statusUpdate"] != nil
    end

    test "receives stream_error on HTTP 500" do
      rpc_id = "rpc-#{unique_id()}"

      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/error500",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      assert_receive {:stream_error, ^rpc_id, 500}, 5000
    end

    test "receives stream_error on HTTP 404" do
      rpc_id = "rpc-#{unique_id()}"

      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/notfound",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      assert_receive {:stream_error, ^rpc_id, 404}, 5000
    end

    test "receives stream_error on connection refused" do
      rpc_id = "rpc-#{unique_id()}"

      # Use a port that's not listening
      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:59999/sse",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      assert_receive {:stream_error, ^rpc_id, error}, 5000
      assert match?({:transport_error, _}, error) or match?(%Mint.TransportError{}, error)
    end

    test "dispatches status update to TaskStore" do
      task_id = unique_id()
      rpc_id = "rpc-#{unique_id()}"

      # Pre-create task in store
      TaskStore.put(%{
        "id" => task_id,
        "status" => %{"state" => "submitted"},
        "artifacts" => []
      })

      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/status?task_id=#{task_id}",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      # Wait for stream to complete
      assert_receive {:stream_init, ^rpc_id, _}, 5000

      # Give time for dispatch
      Process.sleep(100)

      # Verify task was updated
      updated_task = TaskStore.get(task_id)
      assert updated_task != nil
      assert updated_task["status"]["state"] == "working"
    end

    test "handles multiple SSE events in stream" do
      task_id = unique_id()
      rpc_id = "rpc-#{unique_id()}"

      # Pre-create task
      TaskStore.put(%{
        "id" => task_id,
        "status" => %{"state" => "submitted"},
        "artifacts" => []
      })

      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/multi?task_id=#{task_id}",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      # Should receive init
      assert_receive {:stream_init, ^rpc_id, _}, 5000

      # Give time for all events
      Process.sleep(200)

      # Task should be in final state
      updated_task = TaskStore.get(task_id)
      assert updated_task != nil
      assert updated_task["status"]["state"] == "completed"
    end

    test "handles artifact update in stream" do
      task_id = unique_id()
      rpc_id = "rpc-#{unique_id()}"

      # Pre-create task
      TaskStore.put(%{
        "id" => task_id,
        "status" => %{"state" => "working"},
        "artifacts" => []
      })

      {:ok, _pid} =
        SSEClient.start_link(
          url: "http://localhost:#{@test_port}/sse/artifact?task_id=#{task_id}",
          payload: %{"jsonrpc" => "2.0", "method" => "message/stream"},
          headers: [{"content-type", "application/json"}],
          reply_to: self(),
          rpc_id: rpc_id
        )

      assert_receive {:stream_init, ^rpc_id, _}, 5000
      Process.sleep(100)

      # Verify artifact was added
      updated_task = TaskStore.get(task_id)
      assert updated_task != nil
      assert length(updated_task["artifacts"]) > 0
    end
  end

  # ------------------------------------------------------------------
  # Test Server Implementation
  # ------------------------------------------------------------------

  defp start_test_server do
    children = [
      {Plug.Cowboy, scheme: :http, plug: SSETestPlug, options: [port: @test_port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SSETestSupervisor)
  end

  defp stop_test_server(pid) do
    if Process.alive?(pid) do
      Supervisor.stop(pid, :normal, 5000)
    end
  catch
    :exit, _ -> :ok
  end

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule SSETestPlug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case conn.request_path do
      "/sse/success" ->
        send_sse_success(conn)

      "/sse/error500" ->
        send_resp(conn, 500, "Internal Server Error")

      "/sse/notfound" ->
        send_resp(conn, 404, "Not Found")

      "/sse/status" ->
        task_id = conn.query_params["task_id"] || "unknown"
        send_sse_status_update(conn, task_id)

      "/sse/multi" ->
        task_id = conn.query_params["task_id"] || "unknown"
        send_sse_multi_events(conn, task_id)

      "/sse/artifact" ->
        task_id = conn.query_params["task_id"] || "unknown"
        send_sse_artifact(conn, task_id)

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp send_sse_success(conn) do
    event =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "statusUpdate" => %{
            "taskId" => "test-task",
            "status" => %{"state" => "working", "progress" => 50}
          }
        }
      })

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> send_sse_event(event)
    |> close_sse()
  end

  defp send_sse_status_update(conn, task_id) do
    event =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "statusUpdate" => %{
            "taskId" => task_id,
            "status" => %{"state" => "working", "progress" => 75}
          }
        }
      })

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> send_sse_event(event)
    |> close_sse()
  end

  defp send_sse_multi_events(conn, task_id) do
    event1 =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "statusUpdate" => %{
            "taskId" => task_id,
            "status" => %{"state" => "working", "progress" => 25}
          }
        }
      })

    event2 =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "statusUpdate" => %{
            "taskId" => task_id,
            "status" => %{"state" => "working", "progress" => 75}
          }
        }
      })

    event3 =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "statusUpdate" => %{
            "taskId" => task_id,
            "status" => %{"state" => "completed"}
          }
        }
      })

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> send_sse_event(event1)
    |> send_sse_event(event2)
    |> send_sse_event(event3)
    |> close_sse()
  end

  defp send_sse_artifact(conn, task_id) do
    event =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "result" => %{
          "artifactUpdate" => %{
            "taskId" => task_id,
            "artifact" => %{
              "name" => "test-artifact",
              "parts" => [%{"type" => "text", "text" => "streamed content"}]
            }
          }
        }
      })

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    |> send_sse_event(event)
    |> close_sse()
  end

  defp send_sse_event(conn, data) do
    {:ok, conn} = chunk(conn, "data: #{data}\n\n")
    conn
  end

  defp close_sse(conn) do
    conn
  end
end
