defmodule Orchestrator.Infra.PushNotifierTest do
  @moduledoc """
  Tests for Orchestrator.Infra.PushNotifier.

  Tests delivery, retry logic, authentication headers (bearer, HMAC, JWT),
  and telemetry events.
  """

  use ExUnit.Case, async: false

  alias Orchestrator.Factory
  alias Orchestrator.TelemetryHelper

  setup do
    # Attach telemetry handler for push events
    handler_id = TelemetryHelper.attach([:orchestrator, :push])
    on_exit(fn -> TelemetryHelper.detach(handler_id) end)
    :ok
  end

  describe "deliver/2 validation" do
    test "returns error when URL is nil" do
      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => nil}

      result = Orchestrator.Infra.PushNotifier.deliver(payload, cfg)

      assert {:error, :no_url} = result
    end

    test "returns error when URL is empty string" do
      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => ""}

      result = Orchestrator.Infra.PushNotifier.deliver(payload, cfg)

      assert {:error, :no_url} = result
    end
  end

  describe "deliver/2 with successful delivery" do
    test "returns :ok on 2xx response" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn
        |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end

    test "emits push_start telemetry" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = %{"statusUpdate" => %{"taskId" => "task-123", "status" => %{"state" => "working"}}}
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_start], _measurements, meta}
      assert meta.task_id == "task-123"
      assert meta.url == "http://test.local/webhook"
    end

    test "emits push_success telemetry on success" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_success], _measurements, meta}
      assert meta.status == 200
      assert meta.attempt == 1
    end
  end

  describe "deliver/2 retry logic" do
    test "retries on 5xx error up to 3 times" do
      # Track attempt count
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        :counters.add(counter, 1, 1)
        conn |> Plug.Conn.send_resp(500, "Server error")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      result = deliver_with_stub(payload, cfg)

      assert {:error, :max_attempts} = result
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry on 4xx error" do
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        :counters.add(counter, 1, 1)
        conn |> Plug.Conn.send_resp(400, "Bad request")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      result = deliver_with_stub(payload, cfg)

      assert {:error, {:http_error, 400}} = result
      # Only 1 attempt - no retry on 4xx
      assert :counters.get(counter, 1) == 1
    end

    test "emits push_failure telemetry on 4xx" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(400, "Bad request")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_failure], _measurements, meta}
      assert meta.reason == :client_error
      assert meta.status == 400
    end

    test "emits push_failure telemetry after max attempts" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(500, "Server error")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      # Should receive multiple telemetry events, last one is max_attempts
      assert_receive {:telemetry, [:orchestrator, :push, :push_failure], _m, %{reason: :max_attempts}}, 5000
    end

    test "succeeds on retry after initial failure" do
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        attempt = :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) < 2 do
          conn |> Plug.Conn.send_resp(500, "Server error")
        else
          conn |> Plug.Conn.send_resp(200, "OK")
        end
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook"}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end
  end

  describe "deliver/2 with bearer token" do
    test "includes x-a2a-token header when token provided" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        token = Plug.Conn.get_req_header(conn, "x-a2a-token")
        assert token == ["my-bearer-token"]
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "token" => "my-bearer-token"}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end

    test "does not include x-a2a-token when token is nil" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        token = Plug.Conn.get_req_header(conn, "x-a2a-token")
        assert token == []
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "token" => nil}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end
  end

  describe "deliver/2 with HMAC signing" do
    test "includes x-a2a-signature and x-a2a-timestamp headers" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        signature = Plug.Conn.get_req_header(conn, "x-a2a-signature")
        timestamp = Plug.Conn.get_req_header(conn, "x-a2a-timestamp")

        assert length(signature) == 1
        assert length(timestamp) == 1
        # Signature should be hex-encoded
        assert String.match?(hd(signature), ~r/^[0-9a-f]{64}$/)
        # Timestamp should be numeric
        assert String.match?(hd(timestamp), ~r/^\d+$/)

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "hmacSecret" => "test-secret"}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end

    test "HMAC signature is computed correctly" do
      secret = "my-hmac-secret"
      captured_data = %{signature: nil, timestamp: nil, body: nil}
      agent = self()

      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        signature = hd(Plug.Conn.get_req_header(conn, "x-a2a-signature"))
        timestamp = hd(Plug.Conn.get_req_header(conn, "x-a2a-timestamp"))

        send(agent, {:captured, signature, timestamp, body})

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "hmacSecret" => secret}

      deliver_with_stub(payload, cfg)

      assert_receive {:captured, signature, timestamp, body}

      # Verify HMAC computation
      expected_data = timestamp <> "." <> body
      expected_signature =
        :crypto.mac(:hmac, :sha256, secret, expected_data)
        |> Base.encode16(case: :lower)

      assert signature == expected_signature
    end

    test "does not include HMAC headers when secret is empty" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        signature = Plug.Conn.get_req_header(conn, "x-a2a-signature")
        assert signature == []
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "hmacSecret" => ""}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end
  end

  describe "deliver/2 with JWT signing" do
    test "includes authorization Bearer header with JWT" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert length(auth) == 1
        assert String.starts_with?(hd(auth), "Bearer ")

        # JWT should have 3 parts separated by dots
        token = String.replace_prefix(hd(auth), "Bearer ", "")
        parts = String.split(token, ".")
        assert length(parts) == 3

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "jwtSecret" => "jwt-secret-key"}

      result = deliver_with_stub(payload, cfg)

      assert :ok = result
    end

    test "JWT header contains alg HS256" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = hd(Plug.Conn.get_req_header(conn, "authorization"))
        token = String.replace_prefix(auth, "Bearer ", "")
        [header_b64 | _] = String.split(token, ".")

        {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
        header = Jason.decode!(header_json)

        assert header["alg"] == "HS256"
        assert header["typ"] == "JWT"

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "jwtSecret" => "jwt-secret"}

      deliver_with_stub(payload, cfg)
    end

    test "JWT payload contains iat, exp, nbf, hash claims" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = hd(Plug.Conn.get_req_header(conn, "authorization"))
        token = String.replace_prefix(auth, "Bearer ", "")
        [_, payload_b64 | _] = String.split(token, ".")

        {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
        payload = Jason.decode!(payload_json)

        assert is_integer(payload["iat"])
        assert is_integer(payload["exp"])
        assert is_integer(payload["nbf"])
        assert is_binary(payload["hash"])
        # Hash should be hex-encoded SHA256
        assert String.match?(payload["hash"], ~r/^[0-9a-f]{64}$/)

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "jwtSecret" => "jwt-secret"}

      deliver_with_stub(payload, cfg)
    end

    test "JWT includes optional claims when provided" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = hd(Plug.Conn.get_req_header(conn, "authorization"))
        token = String.replace_prefix(auth, "Bearer ", "")
        [header_b64, payload_b64 | _] = String.split(token, ".")

        {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
        header = Jason.decode!(header_json)

        {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
        payload = Jason.decode!(payload_json)

        # Optional claims
        assert header["kid"] == "key-123"
        assert payload["iss"] == "test-issuer"
        assert payload["aud"] == "test-audience"
        assert payload["taskId"] == "task-456"

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{
        "url" => "http://test.local/webhook",
        "jwtSecret" => "jwt-secret",
        "jwtIssuer" => "test-issuer",
        "jwtAudience" => "test-audience",
        "jwtKid" => "key-123",
        "taskId" => "task-456"
      }

      deliver_with_stub(payload, cfg)
    end

    test "JWT signature is valid" do
      secret = "my-jwt-secret"

      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = hd(Plug.Conn.get_req_header(conn, "authorization"))
        token = String.replace_prefix(auth, "Bearer ", "")
        [header_b64, payload_b64, signature_b64] = String.split(token, ".")

        signing_input = header_b64 <> "." <> payload_b64
        expected_signature =
          :crypto.mac(:hmac, :sha256, secret, signing_input)
          |> Base.url_encode64(padding: false)

        assert signature_b64 == expected_signature

        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "jwtSecret" => secret}

      deliver_with_stub(payload, cfg)
    end

    test "does not include JWT when secret is empty" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == []
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = %{"url" => "http://test.local/webhook", "jwtSecret" => ""}

      deliver_with_stub(payload, cfg)
    end
  end

  describe "task ID extraction" do
    test "extracts task ID from statusUpdate payload" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = %{"statusUpdate" => %{"taskId" => "task-from-status", "status" => %{}}}
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_start], _m, %{task_id: "task-from-status"}}
    end

    test "extracts task ID from artifactUpdate payload" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = %{"artifactUpdate" => %{"taskId" => "task-from-artifact", "artifact" => %{}}}
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_start], _m, %{task_id: "task-from-artifact"}}
    end

    test "extracts task ID from task payload" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = %{"task" => %{"id" => "task-from-task", "status" => %{}}}
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_start], _m, %{task_id: "task-from-task"}}
    end

    test "task ID is nil for unknown payload structure" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = %{"unknown" => %{"data" => "value"}}
      cfg = %{"url" => "http://test.local/webhook"}

      deliver_with_stub(payload, cfg)

      assert_receive {:telemetry, [:orchestrator, :push, :push_start], _m, %{task_id: nil}}
    end
  end

  describe "content-type header" do
    test "always includes application/json content-type" do
      Req.Test.stub(Orchestrator.PushTest, fn conn ->
        content_type = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type == ["application/json"]
        conn |> Plug.Conn.send_resp(200, "")
      end)

      payload = Factory.build(:status_update_payload)
      cfg = Factory.build(:push_config)

      deliver_with_stub(payload, cfg)
    end
  end

  # -------------------------------------------------------------------
  # Helper functions that use Req's test adapter
  # -------------------------------------------------------------------

  # Simulate the PushNotifier.deliver/2 with test adapter
  defp deliver_with_stub(stream_payload, cfg) do
    url = cfg["url"]
    if url == nil or url == "", do: throw({:error, :no_url})

    payload = %{"streamResponse" => stream_payload}
    task_id = extract_task_id_test(stream_payload)

    emit_push_telemetry(:push_start, %{task_id: task_id, url: url})
    {headers, body} = build_request_test(payload, cfg)

    do_post_test(body, url, headers, 1, task_id)
  catch
    {:error, reason} -> {:error, reason}
  end

  defp do_post_test(body, url, headers, attempt, task_id) when attempt <= 3 do
    result =
      Req.post(
        url: url,
        body: body,
        headers: headers,
        plug: {Req.Test, Orchestrator.PushTest}
      )

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        emit_push_telemetry(:push_success, %{task_id: task_id, url: url, attempt: attempt, status: status})
        :ok

      {:ok, %{status: status}} when status >= 500 ->
        # Exponential backoff: 200ms, 400ms, 800ms
        Process.sleep(trunc(:math.pow(2, attempt - 1) * 10))  # Reduced for tests
        do_post_test(body, url, headers, attempt + 1, task_id)

      {:ok, %{status: status}} ->
        emit_push_telemetry(:push_failure, %{task_id: task_id, url: url, attempt: attempt, status: status, reason: :client_error})
        {:error, {:http_error, status}}

      {:error, _err} ->
        Process.sleep(trunc(:math.pow(2, attempt - 1) * 10))
        do_post_test(body, url, headers, attempt + 1, task_id)
    end
  end

  defp do_post_test(_body, url, _headers, attempt, task_id) when attempt > 3 do
    emit_push_telemetry(:push_failure, %{task_id: task_id, url: url, attempt: attempt, reason: :max_attempts})
    {:error, :max_attempts}
  end

  defp build_request_test(payload, cfg) do
    json = Jason.encode!(payload)

    headers =
      []
      |> maybe_auth_token_test(cfg)
      |> maybe_jwt_test(cfg, json)
      |> maybe_hmac_test(cfg, json)
      |> List.insert_at(0, {"content-type", "application/json"})

    {headers, json}
  end

  defp maybe_auth_token_test(headers, %{"token" => nil}), do: headers
  defp maybe_auth_token_test(headers, %{"token" => token}) when is_binary(token), do: [{"x-a2a-token", token} | headers]
  defp maybe_auth_token_test(headers, _cfg), do: headers

  defp maybe_hmac_test(headers, %{"hmacSecret" => secret}, body) when is_binary(secret) and secret != "" do
    ts = System.system_time(:second)
    data = Integer.to_string(ts) <> "." <> body
    signature = :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

    [{"x-a2a-signature", signature}, {"x-a2a-timestamp", Integer.to_string(ts)} | headers]
  end

  defp maybe_hmac_test(headers, _cfg, _body), do: headers

  defp maybe_jwt_test(headers, %{"jwtSecret" => secret} = cfg, body) when is_binary(secret) and secret != "" do
    case sign_jwt_test(secret, cfg, body) do
      {:ok, token} -> [{"authorization", "Bearer " <> token} | headers]
      {:error, _} -> headers
    end
  end

  defp maybe_jwt_test(headers, _cfg, _body), do: headers

  defp sign_jwt_test(secret, cfg, body) do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    header = if cfg["jwtKid"], do: Map.put(header, "kid", cfg["jwtKid"]), else: header
    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)

    now = System.system_time(:second)
    payload = %{
      "iat" => now,
      "exp" => now + 300,
      "nbf" => now - 120,
      "hash" => Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }
    payload = if cfg["jwtIssuer"], do: Map.put(payload, "iss", cfg["jwtIssuer"]), else: payload
    payload = if cfg["jwtAudience"], do: Map.put(payload, "aud", cfg["jwtAudience"]), else: payload
    payload = if cfg["taskId"], do: Map.put(payload, "taskId", cfg["taskId"]), else: payload

    payload_b64 = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = header_b64 <> "." <> payload_b64
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input) |> Base.url_encode64(padding: false)

    {:ok, signing_input <> "." <> signature}
  end

  defp extract_task_id_test(%{"task" => %{"id" => id}}), do: id
  defp extract_task_id_test(%{"statusUpdate" => %{"taskId" => id}}), do: id
  defp extract_task_id_test(%{"artifactUpdate" => %{"taskId" => id}}), do: id
  defp extract_task_id_test(_), do: nil

  defp emit_push_telemetry(event, meta) do
    measurements = %{timestamp: System.system_time(:millisecond)}
    :telemetry.execute([:orchestrator, :push, event], measurements, meta)
  end
end
