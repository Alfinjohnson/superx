import Config

# =============================================================================
# Load .env for local development (compile-time)
# =============================================================================

if config_env() == :dev do
  env_file = Path.expand("../../.env", __DIR__)

  if File.exists?(env_file) do
    env_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)

      # Skip comments and empty lines
      unless line == "" or String.starts_with?(line, "#") do
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            # Remove surrounding quotes if present
            value =
              value
              |> String.trim()
              |> String.trim("\"")
              |> String.trim("'")

            # Only set if not already set (allow overrides from shell)
            if System.get_env(key) == nil do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end
    end)
  end
end

config :orchestrator,
  agents_file: System.get_env("AGENTS_FILE"),
  agents: %{},
  push_jwt_ttl_seconds: String.to_integer(System.get_env("PUSH_JWT_TTL_SECONDS", "300")),
  push_jwt_skew_seconds: String.to_integer(System.get_env("PUSH_JWT_SKEW_SECONDS", "120"))

# =============================================================================
# HTTP Client Configuration
# =============================================================================
config :orchestrator, :http,
  timeout: String.to_integer(System.get_env("HTTP_TIMEOUT", "30000")),
  card_timeout: String.to_integer(System.get_env("HTTP_CARD_TIMEOUT", "5000")),
  pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "50"))

# =============================================================================
# Push Notification Configuration
# =============================================================================
config :orchestrator, :push,
  max_attempts: String.to_integer(System.get_env("PUSH_MAX_ATTEMPTS", "3")),
  retry_base_ms: String.to_integer(System.get_env("PUSH_RETRY_BASE_MS", "200"))

# =============================================================================
# Agent Worker Configuration (Circuit Breaker)
# =============================================================================
config :orchestrator, :agent,
  max_in_flight: String.to_integer(System.get_env("AGENT_MAX_IN_FLIGHT", "10")),
  failure_threshold: String.to_integer(System.get_env("AGENT_FAILURE_THRESHOLD", "5")),
  failure_window_ms: String.to_integer(System.get_env("AGENT_FAILURE_WINDOW_MS", "30000")),
  cooldown_ms: String.to_integer(System.get_env("AGENT_COOLDOWN_MS", "30000")),
  call_timeout: String.to_integer(System.get_env("AGENT_CALL_TIMEOUT", "15000"))

# =============================================================================
# Cluster Configuration
# =============================================================================
config :orchestrator, :cluster,
  rpc_timeout: String.to_integer(System.get_env("CLUSTER_RPC_TIMEOUT", "5000")),
  in_flight_timeout: String.to_integer(System.get_env("CLUSTER_IN_FLIGHT_TIMEOUT", "1000")),
  dns_polling_interval: String.to_integer(System.get_env("CLUSTER_DNS_POLLING_INTERVAL", "5000"))

config :req,
  finch: Finch

config :logger, :console,
  format: "$time $metadata[level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"
