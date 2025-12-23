# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
