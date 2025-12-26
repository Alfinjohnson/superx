# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Hybrid PostgreSQL + ETS Caching** - Write-through cache pattern for durability with fast reads
  - `CachedPostgres` adapters for Task, Agent, and PushConfig stores
  - ETS cache provides sub-millisecond reads, PostgreSQL ensures durability
  - Automatic cache warming on startup (skipped in test sandbox mode)
  - Task PubSub broadcasts on all task updates for SSE streaming
- **Protocol-centric module structure** - Reorganized to `Orchestrator.Protocol.A2A.*`
  - `Protocol.A2A.Adapter` - A2A wire format translation
  - `Protocol.A2A.Proxy` - Request forwarding to A2A agents
  - `Protocol.A2A.PushNotifier` - Webhook delivery
- **Per-request webhooks** - Pass webhook URL in `metadata.webhook` for ephemeral notifications
- **Terminal state protection** - Tasks in completed/failed/canceled states cannot be updated
- SSE streaming now handles all update types (task_update, status_update, artifact_update)

### Changed

- **Persistence mode** - Single `postgres_cached` mode with ETS + PostgreSQL hybrid storage
- Agent Store `upsert/1` now properly returns errors instead of silently ignoring them
- Test suite uses Ecto SQL Sandbox in shared mode for GenServer process compatibility
- Unique URL constraint on agents enforced at database level
- UUID validation for push config operations to avoid cast errors
- Health endpoint returns actual database status
- Test suite now 430+ tests with comprehensive coverage

### Fixed

- SSE client correctly handles Finch accumulator pattern
- Fixed sandbox ownership issues with long-lived GenServer processes
- Fixed terminal state validation in task store
- Fixed task ID validation to reject nil/empty IDs
- Fixed push config FK constraint by creating tasks first in tests

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

### Security

- HMAC-SHA256 and JWT signing for push notifications
- Bearer token authentication for agent communication
- No hardcoded secrets (all via environment variables)

[Unreleased]: https://github.com/anthropics/superx/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/anthropics/superx/releases/tag/v0.1.0
