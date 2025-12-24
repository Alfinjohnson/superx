import Config

# Test environment configuration
# Uses in-memory (hybrid) mode by default

config :orchestrator, persistence: :memory

# Disable logging during tests (set to :info to see logs)
config :logger, level: :warning

# Test agents configuration
config :orchestrator,
  agents_file: "test/fixtures/agents.yaml",
  agents: %{}

# Disable push notifications in tests
config :orchestrator, :push_notifications, enabled: false

# Use shorter timeouts in tests
config :orchestrator, :http_client,
  timeout: 5_000,
  recv_timeout: 5_000
