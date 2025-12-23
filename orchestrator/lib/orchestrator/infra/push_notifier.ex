defmodule Orchestrator.Infra.PushNotifier do
  @moduledoc """
  Webhook dispatcher for push notifications with retry/backoff.

  Sends task updates to registered push notification URLs with support for:
  - Bearer token authentication
  - HMAC signature verification
  - JWT signed payloads

  ## Configuration

  Uses the `:orchestrator, :push` config:

      config :orchestrator, :push,
        max_attempts: 3,
        retry_base_ms: 200

  Or via environment variables:
  - PUSH_MAX_ATTEMPTS - Maximum delivery attempts (default: 3)
  - PUSH_RETRY_BASE_MS - Base delay for exponential backoff (default: 200ms)

  ## Retry Strategy

  Uses exponential backoff: base_ms, base_ms*2, base_ms*4... (max configured attempts).
  Retries on server errors (5xx) and network failures.
  """

  require Logger

  # Config access with fallback defaults
  defp push_config, do: Application.get_env(:orchestrator, :push, [])
  defp max_attempts, do: Keyword.get(push_config(), :max_attempts, 3)
  defp retry_base_ms, do: Keyword.get(push_config(), :retry_base_ms, 200)

  @doc """
  Deliver a stream payload to a push notification endpoint.

  ## Options in cfg

  - `"url"` - The webhook URL (required)
  - `"token"` - Bearer token for x-a2a-token header
  - `"hmacSecret"` - Secret for HMAC signature
  - `"jwtSecret"` - Secret for JWT signing
  - `"jwtIssuer"` - JWT issuer claim
  - `"jwtAudience"` - JWT audience claim
  - `"jwtKid"` - JWT key ID header
  """
  @spec deliver(map(), map()) :: :ok | {:error, term()}
  def deliver(_payload, %{"url" => nil}), do: {:error, :no_url}
  def deliver(_payload, %{"url" => ""}), do: {:error, :no_url}

  def deliver(stream_payload, cfg) do
    payload = %{"streamResponse" => stream_payload}
    task_id = extract_task_id(stream_payload)
    url = cfg["url"]

    emit_telemetry(:push_start, %{task_id: task_id, url: url})
    {headers, body} = build_request(payload, cfg)

    do_post(body, url, headers, 1, task_id, max_attempts())
  end

  # ---- Internal ----

  defp do_post(body, url, headers, attempt, task_id, max) when attempt <= max do
    case Req.post(url: url, body: body, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("push delivered", task_id: task_id, url: url, attempt: attempt)
        emit_telemetry(:push_success, %{task_id: task_id, url: url, attempt: attempt, status: status})
        :ok

      {:ok, %{status: status}} when status >= 500 ->
        retry(body, url, headers, attempt, task_id, {:http_error, status}, max)

      {:ok, %{status: status}} ->
        Logger.warning("push failed", task_id: task_id, url: url, status: status, attempt: attempt)
        emit_telemetry(:push_failure, %{task_id: task_id, url: url, attempt: attempt, status: status, reason: :client_error})
        {:error, {:http_error, status}}

      {:error, err} ->
        retry(body, url, headers, attempt, task_id, {:unreachable, err}, max)
    end
  end

  defp do_post(_body, url, _headers, attempt, task_id, max) when attempt > max do
    Logger.error("push giving up", task_id: task_id, url: url, attempt: attempt)
    emit_telemetry(:push_failure, %{task_id: task_id, url: url, attempt: attempt, reason: :max_attempts})
    {:error, :max_attempts}
  end

  defp retry(body, url, headers, attempt, task_id, reason, max) do
    Logger.warning("push retry", task_id: task_id, url: url, attempt: attempt, reason: inspect(reason))
    :timer.sleep(backoff_ms(attempt))
    do_post(body, url, headers, attempt + 1, task_id, max)
  end

  defp backoff_ms(attempt), do: trunc(:math.pow(2, attempt - 1) * retry_base_ms())

  defp build_request(payload, cfg) do
    json = Jason.encode!(payload)

    headers =
      []
      |> maybe_auth_token(cfg)
      |> maybe_jwt(cfg, json)
      |> maybe_hmac(cfg, json)
      |> List.insert_at(0, {"content-type", "application/json"})

    {headers, json}
  end

  defp maybe_auth_token(headers, %{"token" => nil}), do: headers
  defp maybe_auth_token(headers, %{"token" => token}) when is_binary(token), do: [{"x-a2a-token", token} | headers]
  defp maybe_auth_token(headers, _cfg), do: headers

  defp maybe_hmac(headers, %{"hmacSecret" => secret}, body) when is_binary(secret) and secret != "" do
    ts = System.system_time(:second)
    signature = sign_hmac(secret, ts, body)

    [
      {"x-a2a-signature", signature},
      {"x-a2a-timestamp", Integer.to_string(ts)}
      | headers
    ]
  end

  defp maybe_hmac(headers, _cfg, _body), do: headers

  defp maybe_jwt(headers, %{"jwtSecret" => secret} = cfg, body) when is_binary(secret) and secret != "" do
    case sign_jwt(secret, cfg, body) do
      {:ok, token} -> [{"authorization", "Bearer " <> token} | headers]
      {:error, reason} ->
        Logger.warning("push jwt signing failed", reason: inspect(reason))
        headers
    end
  end

  defp maybe_jwt(headers, _cfg, _body), do: headers

  defp sign_hmac(secret, ts, body) do
    data = Integer.to_string(ts) <> "." <> body
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
  end

  defp sign_jwt(secret, cfg, body) do
    with {:ok, header} <- build_jwt_header(cfg),
         {:ok, payload} <- build_jwt_payload(cfg, body) do
      signing_input = header <> "." <> payload
      signature = :crypto.mac(:hmac, :sha256, secret, signing_input) |> base64url()
      {:ok, signing_input <> "." <> signature}
    end
  end

  defp build_jwt_header(cfg) do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    header = maybe_put_claim(header, "kid", cfg["jwtKid"])
    {:ok, base64url(header)}
  end

  defp build_jwt_payload(cfg, body) do
    now = System.system_time(:second)
    ttl = jwt_ttl_seconds()
    skew = jwt_skew_seconds()

    payload =
      %{
        "iat" => now,
        "exp" => now + ttl,
        "nbf" => now - skew,
        "hash" => Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      }
      |> maybe_put_claim("iss", cfg["jwtIssuer"])
      |> maybe_put_claim("aud", cfg["jwtAudience"])
      |> maybe_put_claim("taskId", cfg["taskId"])

    {:ok, base64url(payload)}
  end

  defp maybe_put_claim(map, _key, nil), do: map
  defp maybe_put_claim(map, _key, ""), do: map
  defp maybe_put_claim(map, key, value), do: Map.put(map, key, value)

  defp base64url(map) when is_map(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
  defp base64url(bin) when is_binary(bin), do: Base.url_encode64(bin, padding: false)

  defp jwt_ttl_seconds, do: Application.get_env(:orchestrator, :push_jwt_ttl_seconds, 300)
  defp jwt_skew_seconds, do: Application.get_env(:orchestrator, :push_jwt_skew_seconds, 120)

  defp extract_task_id(%{"task" => %{"id" => id}}), do: id
  defp extract_task_id(%{"statusUpdate" => %{"taskId" => id}}), do: id
  defp extract_task_id(%{"artifactUpdate" => %{"taskId" => id}}), do: id
  defp extract_task_id(_), do: nil

  defp emit_telemetry(event, meta) do
    measurements = %{timestamp: System.system_time(:millisecond)}
    :telemetry.execute([:orchestrator, :push, event], measurements, meta)
  end
end

# Backward compatibility alias
defmodule Orchestrator.PushNotifier do
  @moduledoc false
  defdelegate deliver(payload, cfg), to: Orchestrator.Infra.PushNotifier
end
