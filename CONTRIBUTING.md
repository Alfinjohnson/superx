# Contributing to SuperX

Thank you for your interest in contributing to SuperX! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and constructive in all interactions. We welcome contributions from everyone.

## Getting Started

### Prerequisites

- Elixir 1.19+
- OTP 28+
- Docker (optional, for MCP Docker transport testing)

### Setup

```bash
# Clone the repository
git clone https://github.com/superx/orchestrator.git
cd orchestrator

# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test --exclude stress
```

## Development Workflow

### Running Tests

```bash
# Run tests (excludes stress tests by default in CI)
mix test --exclude stress

# Run all tests including stress tests (~65 seconds)
mix test

# Run only stress tests
mix test test/stress/

# Run with coverage
mix test --cover --exclude stress

# Run specific test file
mix test test/protocol/mcp/session_test.exs
```

### Code Style

We use the default Elixir formatter. Before committing:

```bash
mix format
mix format --check-formatted  # CI check
```

### Type Checking

```bash
mix dialyzer
```

## Making Changes

### Branch Naming

- `feature/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation changes
- `refactor/` - Code refactoring

### Commit Messages

Follow conventional commits:

```
type(scope): description

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Examples:
- `feat(agent): add batch upsert support`
- `fix(circuit-breaker): handle timeout correctly`
- `docs(readme): update quick start guide`

### Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Add/update tests as needed
5. Ensure all tests pass
6. Update documentation if needed
7. Submit a pull request

### PR Checklist

- [ ] Tests pass (`mix test --exclude stress`)
- [ ] Code is formatted (`mix format --check-formatted`)
- [ ] Documentation updated (if applicable)
- [ ] CHANGELOG.md updated (for user-facing changes)
- [ ] No compiler warnings (`mix compile --warnings-as-errors`)

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for an overview of the codebase structure.

### Key Modules

| Module | Purpose |
|--------|---------|
| `Orchestrator.Router` | HTTP endpoint handling |
| `Orchestrator.Agent.*` | Agent management (Store, Loader, Worker) |
| `Orchestrator.Task.*` | Task management (Store, Streaming) |
| `Orchestrator.Protocol.A2A.*` | A2A protocol (Adapter, Proxy, PushNotifier) |
| `Orchestrator.Protocol.MCP.*` | MCP protocol (Session, Supervisor, Transports) |
| `Orchestrator.Web.*` | Web layer (Streaming, AgentCard) |

### Protocol Support

- **A2A v0.3.0** - Agent-to-Agent protocol for agent discovery and task execution
- **MCP v2024-11-05** - Model Context Protocol with multi-transport support (HTTP/SSE, STDIO, Docker)

## Testing Guidelines

### Test Organization

- `test/` - Unit and integration tests
- `test/stress/` - Performance and stress tests (tagged with `@moduletag :stress`)
- `test/support/` - Test helpers and factories
- `test/protocol/` - Protocol-specific tests (A2A, MCP)

### Writing Tests

```elixir
defmodule MyModuleTest do
  use Orchestrator.DataCase, async: true
  
  describe "function_name/arity" do
    test "describes expected behavior" do
      # Arrange
      input = build(:some_factory)
      
      # Act
      result = MyModule.function_name(input)
      
      # Assert
      assert result == expected
    end
  end
end
```

### Stress Tests

Tag long-running stress tests:

```elixir
@moduletag :stress
@tag timeout: 120_000
```

## Questions?

- Open an issue for bugs or feature requests
- Start a discussion for questions or ideas

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
