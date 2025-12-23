defmodule Orchestrator.Infra.HttpClient do
  @moduledoc """
  Shared HTTP client for external requests.

  All HTTP calls to external services (agents, webhooks, etc.) should
  go through this module to ensure consistent:
  - Timeout handling
  - Error formatting
  - Telemetry emission
  - Connection pooling (via Finch)

  ## Configuration

  Uses the `:orchestrator, :http` config:

      config :orchestrator, :http,
        timeout: 30_000,
        card_timeout: 5_000,
        pool_size: 50

  Or via environment variables:
  - HTTP_TIMEOUT - Default request timeout (ms)
  - HTTP_CARD_TIMEOUT - Agent card fetch timeout (ms)
  - HTTP_POOL_SIZE - Connection pool size
  """

  require Logger

  @finch_name Orchestrator.Finch

  # Config access with fallback defaults
  defp http_config, do: Application.get_env(:orchestrator, :http, [])
  defp default_timeout, do: Keyword.get(http_config(), :timeout, 30_000)
  defp default_card_timeout, do: Keyword.get(http_config(), :card_timeout, 5_000)

  # -------------------------------------------------------------------
  # JSON Requests
  # -------------------------------------------------------------------

  @doc """
  POST JSON to a URL and return decoded response.

  ## Options
  - `:timeout` - Request timeout in ms (default: 30000)
  - `:headers` - Additional headers

  ## Returns
  - `{:ok, body}` - Successful response with decoded JSON body
  - `{:error, {:http, status, body}}` - Non-2xx response
  - `{:error, :timeout}` - Request timed out
  - `{:error, :decode}` - Failed to decode JSON
  - `{:error, reason}` - Other transport errors
  """
  @spec post_json(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_json(url, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    headers = Keyword.get(opts, :headers, [])

    start_time = System.monotonic_time(:millisecond)

    result =
      Req.post(url,
        json: body,
        headers: headers,
        finch: @finch_name,
        receive_timeout: timeout
      )

    duration = System.monotonic_time(:millisecond) - start_time
    emit_telemetry(:post, url, result, duration)

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Jason.DecodeError{}} ->
        {:error, :decode}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  GET JSON from a URL.

  ## Options
  - `:timeout` - Request timeout in ms (default: 5000)
  - `:headers` - Additional headers
  """
  @spec get_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_json(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_card_timeout())
    headers = Keyword.get(opts, :headers, [])

    start_time = System.monotonic_time(:millisecond)

    result =
      Req.get(url,
        headers: headers,
        finch: @finch_name,
        receive_timeout: timeout
      )

    duration = System.monotonic_time(:millisecond) - start_time
    emit_telemetry(:get, url, result, duration)

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
  end

  # -------------------------------------------------------------------
  # Agent Card Fetching
  # -------------------------------------------------------------------

  @doc """
  Fetch an agent card from a URL.

  ## Options
  - `:timeout` - Request timeout in ms (default: 5000)
  """
  @spec fetch_agent_card(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_agent_card(url, opts \\ []) do
    case get_json(url, opts) do
      {:ok, card} when is_map(card) ->
        {:ok, card}

      {:error, {:http, status, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Failed to fetch agent card from #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Raw Requests (for streaming, etc.)
  # -------------------------------------------------------------------

  @doc """
  Make a raw POST request returning the full Req response.
  Used for streaming and other advanced use cases.
  """
  @spec post_raw(String.t(), map(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post_raw(url, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    extra_opts = Keyword.get(opts, :req_opts, [])

    Req.post(
      url,
      [json: body, finch: @finch_name, receive_timeout: timeout] ++ extra_opts
    )
  end

  # -------------------------------------------------------------------
  # Telemetry
  # -------------------------------------------------------------------

  defp emit_telemetry(method, url, result, duration_ms) do
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
