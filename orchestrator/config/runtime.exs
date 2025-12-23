import Config

# Runtime configuration for Mix releases
# This file is executed at runtime, not compile time
# All System.get_env calls here happen when the release starts
# Note: .env loading for local dev is handled in config.exs

# =============================================================================
# Persistence Mode
# =============================================================================

persistence_mode =
  case {config_env(), System.get_env("SUPERX_PERSISTENCE")} do
    # Test env: default to memory unless explicitly set to postgres
    {:test, value} when is_binary(value) ->
      case String.trim(value) do
        "postgres" -> :postgres
        _ -> :memory
      end

    {:test, _} ->
      :memory

    # Non-test: default to postgres unless explicitly set to memory
    {_, value} when is_binary(value) ->
      case String.trim(value) do
        "memory" -> :memory
        _ -> :postgres
      end

    {_, _} ->
      :postgres
  end

config :orchestrator, persistence: persistence_mode

# =============================================================================
# Server Configuration
# =============================================================================

config :orchestrator, :port, String.to_integer(System.get_env("PORT", "4000"))

# =============================================================================
# PostgreSQL Configuration (only used in postgres mode)
# =============================================================================

if persistence_mode == :postgres do
  database_url = System.get_env("DATABASE_URL")

  if database_url do
    config :orchestrator, Orchestrator.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
      queue_target: 50,
      queue_interval: 1000,
      ssl: System.get_env("DB_SSL", "false") == "true",
      ssl_opts: [verify: :verify_none]
  else
    config :orchestrator, Orchestrator.Repo,
      username: System.get_env("DB_USER", "postgres"),
      password: System.get_env("DB_PASSWORD", "postgres"),
      hostname: System.get_env("DB_HOST", "localhost"),
      database: System.get_env("DB_NAME", "superx_prod"),
      port: String.to_integer(System.get_env("DB_PORT", "5432")),
      pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
      queue_target: 50,
      queue_interval: 1000,
      ssl: System.get_env("DB_SSL", "false") == "true",
      ssl_opts: [verify: :verify_none]
  end
end

# =============================================================================
# Agent Configuration
# =============================================================================

if agents_file = System.get_env("AGENTS_FILE") do
  config :orchestrator, agents_file: agents_file
end

# =============================================================================
# Push Notifications
# =============================================================================

config :orchestrator,
  push_jwt_ttl_seconds: String.to_integer(System.get_env("PUSH_JWT_TTL_SECONDS", "300")),
  push_jwt_skew_seconds: String.to_integer(System.get_env("PUSH_JWT_SKEW_SECONDS", "120"))

# =============================================================================
# Logging
# =============================================================================

log_level =
  case System.get_env("LOG_LEVEL", "info") do
    "debug" -> :debug
    "info" -> :info
    "warning" -> :warning
    "warn" -> :warning
    "error" -> :error
    _ -> :info
  end

config :logger, level: log_level

# =============================================================================
# Release Configuration
# =============================================================================

if config_env() == :prod do
  # Ensure we have required configuration for production
  if persistence_mode == :postgres do
    database_url = System.get_env("DATABASE_URL")
    db_host = System.get_env("DB_HOST")

    if is_nil(database_url) and is_nil(db_host) do
      raise """
      PostgreSQL configuration missing.
      Set DATABASE_URL or DB_HOST environment variable.
      Or use SUPERX_PERSISTENCE=memory for stateless mode.
      """
    end
  end
end
