import Config

# Test environment configuration
# Persistence mode is determined by SUPERX_PERSISTENCE env var at runtime
# Default is :memory (set in runtime.exs for test env)

# Test database configuration (used when persistence: :postgres)
config :orchestrator, Orchestrator.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "superx_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Disable logging during tests (set to :info to see logs)
config :logger, level: :warning

# Test agents configuration
config :orchestrator,
  agents_file: "test/fixtures/agents.yaml",
  agents: %{}

# Disable push notifications in tests
config :orchestrator, :push_notifications,
  enabled: false

# Use shorter timeouts in tests
config :orchestrator, :http_client,
  timeout: 5_000,
  recv_timeout: 5_000
