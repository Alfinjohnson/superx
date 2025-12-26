import Config

# Test environment
config :logger, level: :warning

# Disable HTTP server during tests; the application still starts Repo and caches
config :orchestrator, :start_http, false
