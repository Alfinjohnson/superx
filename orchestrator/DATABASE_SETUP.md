# SuperX Orchestrator - PostgreSQL Setup

SuperX uses **PostgreSQL with ETS caching** for all environments (dev, test, production).

## Quick Start

### 1. Start PostgreSQL

Using Docker (recommended):
```bash
docker-compose up -d
```

Or use your own PostgreSQL instance.

### 2. Set Database URL

Development:
```bash
export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/orchestrator_dev"
```

Test:
```bash
export DATABASE_URL="postgresql://postgres:postgres@localhost:5433/orchestrator_test"
```

Production:
```bash
export DATABASE_URL="postgresql://user:password@prod-host:5432/orchestrator_prod"
```

### 3. Create Database & Run Migrations

```bash
mix ecto.setup
```

Or manually:
```bash
mix ecto.create
mix ecto.migrate
```

### 4. Run the Server

```bash
mix run --no-halt
```

Or in development with live reload:
```bash
iex -S mix
```

## Running Tests

Tests use the PostgreSQL test database with Ecto sandbox for isolation:

```bash
# Make sure test database is running
docker-compose up -d postgres_test

# Run all tests
mix test
```

## Architecture

SuperX uses a **hybrid persistence approach**:

- **PostgreSQL**: Provides ACID guarantees, durability, crash recovery
- **ETS Cache**: Provides sub-millisecond read performance (< 1ms)
- **Write-through caching**: All writes go to PostgreSQL first, then cache

### Performance
- **Reads**: ~0.5ms (ETS cache hit)
- **Writes**: ~5ms (PostgreSQL + cache update)
- **Cache misses**: ~5ms (PostgreSQL + cache populate)

### Benefits
- ✅ **Durable**: No data loss on crash
- ✅ **Fast**: Cache provides memory-speed reads
- ✅ **ACID**: PostgreSQL transactions
- ✅ **Cluster-friendly**: Each node maintains its own cache
- ✅ **Test-friendly**: Ecto sandbox for test isolation

## Database Schema

The system uses three main tables:

### `tasks`
Stores task state, messages, results, and artifacts.

### `agents`
Stores registered agent configurations and metadata.

### `push_configs`
Stores webhook configurations for task notifications.

## Configuration

### Environment Variables

- `DATABASE_URL`: PostgreSQL connection string (required)
- `DB_POOL_SIZE`: Connection pool size (default: 10)
- `PORT`: HTTP server port (default: 4000)

### Example

```bash
export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/orchestrator_dev"
export DB_POOL_SIZE="20"
export PORT="4000"

mix run --no-halt
```

## Troubleshooting

### Database connection issues

```bash
# Check PostgreSQL is running
docker-compose ps

# View PostgreSQL logs
docker-compose logs postgres

# Restart PostgreSQL
docker-compose restart postgres
```

### Reset database

```bash
mix ecto.reset
```

This will drop, recreate, and migrate the database.

### Check database status

```bash
mix ecto.migrations
```
