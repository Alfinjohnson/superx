# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Hybrid task management** - OTP-managed in-memory tasks by default; Postgres archival planned
- **Per-request webhooks** - Pass webhook URL in `metadata.webhook` for ephemeral notifications without pre-configuration
- Streaming integration test suite for `message/stream` and `tasks/subscribe` endpoints
- Advanced stress testing scenarios for concurrent streaming connections
- Long-running stream stability tests (60s+ sustained connections)
- High-frequency SSE event flooding tests
- Client disconnect mid-stream error handling tests
- Stream initialization timeout tests
- Simplified persistence surface; removed task storage mode helpers

### Changed

- Removed `SUPERX_TASK_STORAGE`; hybrid mode is default and requires no toggle
- `tasks.get` and `tasks.subscribe` always available; return -32004 when task is missing
- `PushConfig.deliver_event/3` now accepts optional per-request webhook configuration
- Envelope struct includes `webhook` field for per-request webhook passthrough
- Moved CHANGELOG.md to repository root for better visibility
- Updated test documentation to reflect actual streaming test structure

### Fixed

- Health endpoint now correctly handles memory persistence mode (returns "n/a" for db status)

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

- **Persistence**
  - Dual persistence modes: PostgreSQL (default) and Memory (stateless)
  - Agent loader from `agents.yml`, config, and environment variables
  - Task and push config persistence with JSONB storage

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
  - Health endpoint with database and cluster status
  - Request logging with request IDs

- **Developer Experience**
  - Well-documented README with examples
  - 210 tests with both memory and PostgreSQL modes
  - Factory helpers for testing
  - Stress test suite

### Security

- HMAC-SHA256 and JWT signing for push notifications
- Bearer token authentication for agent communication
- No hardcoded secrets (all via environment variables)

[Unreleased]: https://github.com/superx/orchestrator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/superx/orchestrator/releases/tag/v0.1.0
