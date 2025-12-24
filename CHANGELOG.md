# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **MCP Protocol Support** - Full implementation of Anthropic's Model Context Protocol (v2024-11-05)
  - Protocol adapter for MCP JSON-RPC messages
  - HTTP transport (streamable-http, SSE) for remote MCP servers
  - STDIO transport for local MCP server processes
  - Docker/OCI transport for containerized MCP servers
  - Stateful MCP.Session GenServer for connection management
  - Bidirectional request handling (sampling, roots, elicitation)
  - Environment variable expansion in agent configuration (`${VAR_NAME}`)
  - MCP registry file support for bulk server imports
- **Protocol-centric module structure** - Reorganized to `Orchestrator.Protocol.{A2A,MCP}.*`
  - `Protocol.A2A.Adapter` - A2A wire format translation
  - `Protocol.A2A.Proxy` - Request forwarding to A2A agents
  - `Protocol.A2A.PushNotifier` - Webhook delivery
  - `Protocol.MCP.Adapter` - MCP wire format translation
  - `Protocol.MCP.Session` - Stateful session management
  - `Protocol.MCP.Supervisor` - Session lifecycle supervision
  - `Protocol.MCP.Transport.*` - HTTP, STDIO, Docker transports
- **Pure OTP in-memory task management** - Tasks stored via Horde + ETS, no external dependencies
- **Per-request webhooks** - Pass webhook URL in `metadata.webhook` for ephemeral notifications
- **SSE streaming integration tests** - Production-grade tests for `message/stream` and `tasks/subscribe`
- Stress testing scenarios for concurrent streaming connections
- Long-running stream stability tests (60s+ sustained connections)
- Comprehensive MCP protocol test coverage (adapters, session, supervisor, transports)

### Changed

- **Removed PostgreSQL dependency** - SuperX now runs without any database
- **Protocol modules restructured** for better organization and extensibility
- Backward compatibility maintained via module aliases (old imports still work)
- Simplified architecture: removed Ecto, Repo, migrations, and all postgres adapters
- `tasks.get` and `tasks.subscribe` always available; return -32004 when task is missing
- `PushConfig.deliver_event/3` accepts optional per-request webhook configuration
- Envelope struct includes `webhook` field for per-request webhook passthrough
- Updated Docker image to exclude database dependencies
- Simplified CI pipeline - single test job, no database services required
- Health endpoint returns `"n/a"` for db status (memory mode only)
- Circuit breaker recovery test optimized (3 cycles instead of 5, faster cooldown)
- Test suite now 276+ tests with 32%+ coverage

### Removed

- PostgreSQL support and all related code:
  - `Orchestrator.Repo` module
  - `priv/db/migrations/` directory
  - Ecto schemas (`Schema.Task`, `Schema.Agent`, `Schema.PushConfig`)
  - PostgreSQL adapters for task, agent, and push config storage
  - `ecto_sql`, `postgrex` dependencies
  - `SUPERX_PERSISTENCE` environment variable (always in-memory now)
  - `DATABASE_URL`, `DB_HOST`, `DB_*` environment variables
- Outdated documentation files (architecture.md, configuration.md, deployment.md, etc.)

### Fixed

- SSE client correctly handles Finch accumulator pattern (returns state, not `{:cont, state}`)
- Fixed compiler warnings in test files (unused variables, unreachable clauses)

## [0.1.0] - 2024-12-23

### Added

- **Core Gateway Features**
  - JSON-RPC 2.0 API endpoint at `/rpc`
  - A2A protocol v0.3.0 support
  - Agent management (list, get, upsert, delete, health, refreshCard)
  - Task management with persistence
  - Real-time SSE streaming for task updates

- **Resilience**
  - Circuit breaker for failing agents (auto-recovery)
  - Backpressure with configurable max in-flight requests
  - Automatic agent health monitoring

- **Push Notifications**
  - Webhook delivery with retry logic
  - HMAC-SHA256 request signing
  - JWT token generation with configurable claims
  - Simple bearer token support

- **Clustering**
  - Horde-based distributed registry and supervisor
  - libcluster integration for node discovery
  - Support for gossip, DNS, and Kubernetes strategies

- **Observability**
  - Comprehensive telemetry events for agents, tasks, and push notifications
  - Health endpoint with cluster status
  - Request logging with request IDs

- **Developer Experience**
  - Well-documented README with examples
  - 230+ tests with comprehensive coverage
  - Factory helpers for testing
  - Stress test suite

### Security

- HMAC-SHA256 and JWT signing for push notifications
- Bearer token authentication for agent communication
- No hardcoded secrets (all via environment variables)

[Unreleased]: https://github.com/superx/orchestrator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/superx/orchestrator/releases/tag/v0.1.0
