# Contributing to SuperX

Thank you for your interest in contributing to SuperX! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and constructive in all interactions. We welcome contributions from everyone.

## Getting Started

### Prerequisites

- Elixir 1.19+
- PostgreSQL 14+ (for full test suite)
- Docker (optional, for running PostgreSQL)

### Setup

```bash
# Clone the repository
git clone https://github.com/superx/orchestrator.git
cd orchestrator

# Install dependencies
mix deps.get

# Start PostgreSQL (if using Docker)
docker run --name superx-postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=superx_dev \
  -p 5432:5432 -d postgres:16-alpine

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Run tests
mix test
```

## Development Workflow

### Running Tests

```bash
# Run tests in memory mode (default, no DB required)
mix test

# Include PostgreSQL-only tests (requires DB)
mix test --include postgres_only

# Run with coverage
mix coveralls
```

### Code Style

We use the default Elixir formatter. Before committing:

```bash
mix format
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

- [ ] Tests pass (`mix test`)
- [ ] Code is formatted (`mix format`)
- [ ] Documentation updated (if applicable)
- [ ] CHANGELOG.md updated (for user-facing changes)
- [ ] No compiler warnings

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for an overview of the codebase structure.

### Key Modules

| Module | Purpose |
|--------|---------|
| `Orchestrator.Router` | HTTP endpoint handling |
| `Orchestrator.Agent.*` | Agent management domain |
| `Orchestrator.Task.*` | Task management domain |
| `Orchestrator.Protocol.*` | A2A protocol handling |
| `Orchestrator.Infra.*` | Infrastructure (HTTP, SSE, Push) |

## Testing Guidelines

### Test Organization

- `test/` - Unit and integration tests
- `test/stress/` - Performance and stress tests
- `test/support/` - Test helpers and factories

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

### PostgreSQL-Specific Tests

Tag tests that require PostgreSQL:

```elixir
@moduletag :postgres_only
```

## Questions?

- Open an issue for bugs or feature requests
- Start a discussion for questions or ideas

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
