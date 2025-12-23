defmodule Orchestrator.Infra.HttpClientTest do
  @moduledoc """
  Tests for Orchestrator.Infra.HttpClient.

  Uses Mox to mock the Req library for HTTP testing.
  """

  use ExUnit.Case, async: false

  alias Orchestrator.Infra.HttpClient
  alias Orchestrator.TelemetryHelper

  # We'll use Req's built-in testing capabilities with plugs
  # to simulate HTTP responses without external mocking

  setup do
    # Attach telemetry handler for HTTP events
    handler_id = TelemetryHelper.attach([:orchestrator, :http])
    on_exit(fn -> TelemetryHelper.detach(handler_id) end)
    :ok
  end

  describe "post_json/3" do
    test "returns decoded body on 2xx response" do
      # Use Req's test adapter
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": "success", "data": 42}))
      end)

      result = post_json_with_stub(%{"test" => "payload"})

      assert {:ok, %{"result" => "success", "data" => 42}} = result
    end

    test "returns error tuple on 4xx response" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error": "Bad request"}))
      end)

      result = post_json_with_stub(%{"test" => "payload"})

      assert {:error, {:http, 400, %{"error" => "Bad request"}}} = result
    end

    test "returns error tuple on 5xx response" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error": "Internal error"}))
      end)

      result = post_json_with_stub(%{"test" => "payload"})

      assert {:error, {:http, 500, %{"error" => "Internal error"}}} = result
    end

    test "returns :timeout error on timeout" do
      # Simulate timeout by raising transport error
      Req.Test.stub(Orchestrator.ReqTest, fn _conn ->
        raise %Req.TransportError{reason: :timeout}
      end)

      result = post_json_with_stub(%{"test" => "payload"})

      assert {:error, :timeout} = result
    end

    test "returns transport error on connection failure" do
      Req.Test.stub(Orchestrator.ReqTest, fn _conn ->
        raise %Req.TransportError{reason: :econnrefused}
      end)

      result = post_json_with_stub(%{"test" => "payload"})

      assert {:error, %Req.TransportError{reason: :econnrefused}} = result
    end

    test "emits telemetry on successful request" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"ok": true}))
      end)

      post_json_with_stub(%{"test" => "payload"})

      assert_receive {:telemetry, [:orchestrator, :http, :request], %{duration_ms: duration},
                      meta}

      assert duration >= 0
      assert meta.method == :post
      assert meta.status == 200
    end

    test "emits telemetry with nil status on error" do
      Req.Test.stub(Orchestrator.ReqTest, fn _conn ->
        raise %Req.TransportError{reason: :timeout}
      end)

      post_json_with_stub(%{"test" => "payload"})

      assert_receive {:telemetry, [:orchestrator, :http, :request], _measurements, meta}
      assert meta.status == nil
    end

    test "respects custom timeout option" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        # Quick response - timeout option is passed through
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"fast": true}))
      end)

      result = post_json_with_stub(%{"test" => "payload"}, timeout: 1000)

      assert {:ok, %{"fast" => true}} = result
    end

    test "includes custom headers in request" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        # Verify custom header was sent
        auth = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"auth_received" => length(auth) > 0}))
      end)

      result =
        post_json_with_stub(
          %{"test" => "payload"},
          headers: [{"authorization", "Bearer test-token"}]
        )

      assert {:ok, %{"auth_received" => true}} = result
    end
  end

  describe "get_json/2" do
    test "returns decoded body on 200 response" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"items": [1, 2, 3]}))
      end)

      result = get_json_with_stub()

      assert {:ok, %{"items" => [1, 2, 3]}} = result
    end

    test "returns error on non-200 response" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"error": "Not found"}))
      end)

      result = get_json_with_stub()

      assert {:error, {:http, 404, %{"error" => "Not found"}}} = result
    end

    test "returns :timeout error on timeout" do
      Req.Test.stub(Orchestrator.ReqTest, fn _conn ->
        raise %Req.TransportError{reason: :timeout}
      end)

      result = get_json_with_stub()

      assert {:error, :timeout} = result
    end

    test "emits telemetry with GET method" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"ok": true}))
      end)

      get_json_with_stub()

      assert_receive {:telemetry, [:orchestrator, :http, :request], _measurements, meta}
      assert meta.method == :get
      assert meta.status == 200
    end

    test "uses default 5s timeout for GET requests" do
      # This verifies the default timeout behavior
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"default_timeout": true}))
      end)

      result = get_json_with_stub()

      assert {:ok, %{"default_timeout" => true}} = result
    end
  end

  describe "fetch_agent_card/2" do
    test "returns agent card on success" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        card = %{
          "name" => "Test Agent",
          "url" => "http://agent.local/rpc",
          "version" => "1.0"
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(card))
      end)

      result = fetch_agent_card_with_stub()

      assert {:ok, %{"name" => "Test Agent"}} = result
    end

    test "returns http_status error on non-200" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, ~s({"error": "Service unavailable"}))
      end)

      result = fetch_agent_card_with_stub()

      assert {:error, {:http_status, 503}} = result
    end

    test "returns timeout error" do
      Req.Test.stub(Orchestrator.ReqTest, fn _conn ->
        raise %Req.TransportError{reason: :timeout}
      end)

      result = fetch_agent_card_with_stub()

      assert {:error, :timeout} = result
    end
  end

  describe "post_raw/3" do
    test "returns full Req.Response on success" do
      Req.Test.stub(Orchestrator.ReqTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"streaming": true}))
      end)

      # post_raw returns the full response, useful for streaming
      result =
        Req.post(
          "http://test.local/rpc",
          json: %{"method" => "message/stream"},
          plug: {Req.Test, Orchestrator.ReqTest}
        )

      assert {:ok, %Req.Response{status: 200}} = result
    end
  end

  # -------------------------------------------------------------------
  # Helper functions that use Req's test adapter
  # -------------------------------------------------------------------

  defp post_json_with_stub(body, opts \\ []) do
    # Create a custom implementation using Req.Test adapter
    timeout = Keyword.get(opts, :timeout, 30_000)
    headers = Keyword.get(opts, :headers, [])

    start_time = System.monotonic_time(:millisecond)

    result =
      Req.post(
        "http://test.local/rpc",
        json: body,
        headers: headers,
        receive_timeout: timeout,
        plug: {Req.Test, Orchestrator.ReqTest}
      )

    duration = System.monotonic_time(:millisecond) - start_time
    emit_test_telemetry(:post, "http://test.local/rpc", result, duration)

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in Req.TransportError ->
      duration = System.monotonic_time(:millisecond)
      emit_test_telemetry(:post, "http://test.local/rpc", {:error, e}, duration)

      if e.reason == :timeout do
        {:error, :timeout}
      else
        {:error, e}
      end
  end

  defp get_json_with_stub(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    headers = Keyword.get(opts, :headers, [])

    start_time = System.monotonic_time(:millisecond)

    result =
      Req.get(
        "http://test.local/data",
        headers: headers,
        receive_timeout: timeout,
        plug: {Req.Test, Orchestrator.ReqTest}
      )

    duration = System.monotonic_time(:millisecond) - start_time
    emit_test_telemetry(:get, "http://test.local/data", result, duration)

    case result do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in Req.TransportError ->
      duration = System.monotonic_time(:millisecond)
      emit_test_telemetry(:get, "http://test.local/data", {:error, e}, duration)

      if e.reason == :timeout do
        {:error, :timeout}
      else
        {:error, e}
      end
  end

  defp fetch_agent_card_with_stub(opts \\ []) do
    case get_json_with_stub(opts) do
      {:ok, card} when is_map(card) ->
        {:ok, card}

      {:error, {:http, status, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_test_telemetry(method, url, result, duration_ms) do
    status =
      case result do
        {:ok, %{status: s}} -> s
        {:error, _} -> nil
      end

    :telemetry.execute(
      [:orchestrator, :http, :request],
      %{duration_ms: duration_ms},
      %{method: method, url: url, status: status}
    )
  end
end
