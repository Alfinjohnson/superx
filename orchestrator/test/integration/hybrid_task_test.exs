defmodule Orchestrator.Integration.HybridTaskTest do
  @moduledoc """
  Integration coverage for hybrid mode (memory + distributed store).

  Validates tasks.subscribe SSE stream and task updates without Postgres.
  Also validates per-request webhook delivery via PushConfig.
  """

  use Orchestrator.ConnCase, async: false

  alias Orchestrator.Router
  alias Orchestrator.Task.Store, as: TaskStore
  alias Orchestrator.Task.PushConfig

  defmodule PushSpy do
    def deliver(payload, cfg) do
      owner = :persistent_term.get(:push_test_owner, nil)
      if owner, do: send(owner, {:push, payload, cfg})
      :ok
    end
  end

  setup do
    prev = Application.get_env(:orchestrator, :push_notifier)
    Application.put_env(:orchestrator, :push_notifier, PushSpy)
    :persistent_term.put(:push_test_owner, self())

    on_exit(fn ->
      Application.put_env(:orchestrator, :push_notifier, prev)
      :persistent_term.erase(:push_test_owner)
    end)

    :ok
  end

  # Helper to create a POST request with JSON body
  defp json_post(path, body) do
    json_body = Jason.encode!(body)

    :post
    |> conn(path, json_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "tasks.subscribe (hybrid)" do
    test "streams and completes on terminal update" do
      task_id = "hybrid-int-" <> unique_id()

      task = %{"id" => task_id, "status" => %{"state" => "working"}, "artifacts" => []}
      assert :ok = TaskStore.put(task)

      request = %{
        "jsonrpc" => "2.0",
        "id" => "sub-int",
        "method" => "tasks.subscribe",
        "params" => %{"taskId" => task_id}
      }

      stream_task =
        Task.async(fn ->
          conn = json_post("/rpc", request)

          assert conn.status == 200
          assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
          assert conn.state == :chunked

          conn
        end)

      # Allow subscription to attach
      Process.sleep(50)

      # Terminal update should end the stream loop
      completed = Map.put(task, "status", %{"state" => "completed"})
      assert :ok = TaskStore.put(completed)

      assert Task.await(stream_task, 2_000)
    end

    test "per-request webhook delivers via push notifier" do
      task_id = "hybrid-hook-" <> unique_id()
      task = %{"id" => task_id, "status" => %{"state" => "working"}}

      # Per-request webhook config
      webhook = %{"url" => "https://example.com/hook", "token" => "abc"}

      PushConfig.deliver_event(task_id, %{"task" => task}, webhook)

      assert_receive {:push, payload, cfg}, 500
      assert payload["task"]["id"] == task_id
      assert cfg["url"] == webhook["url"]
    end
  end

  defp unique_id do
    :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
  end
end
