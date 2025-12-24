import Config

# Runtime configuration for Mix releases
# This file is executed at runtime, not compile time
# All System.get_env calls here happen when the release starts
# Note: .env loading for local dev is handled in config.exs

# =============================================================================
# Persistence Mode
# =============================================================================
# SuperX uses hybrid mode by default: OTP-managed in-memory task storage.
# PostgreSQL support is available for optional task archival (future feature).

persistence_mode = :memory

config :orchestrator, persistence: persistence_mode

# Hybrid mode: tasks always stored in-memory via Horde/ETS

# =============================================================================
# Server Configuration
# =============================================================================

config :orchestrator, :port, String.to_integer(System.get_env("PORT", "4000"))

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

# No database required - hybrid mode uses in-memory storage by default
