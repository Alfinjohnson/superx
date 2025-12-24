# =============================================================================
# SuperX Orchestrator - Production Dockerfile
# =============================================================================
# Multi-stage build for minimal production image
# =============================================================================

# Stage 1: Build
# =============================================================================
FROM elixir:1.19-slim AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set build environment
ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first (better caching)
COPY mix.exs mix.lock ./
COPY config config

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY lib lib

# Compile and build release
RUN mix compile
RUN mix release

# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM debian:trixie-slim AS runtime

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create non-root user
RUN useradd --create-home --shell /bin/bash app
WORKDIR /home/app
USER app

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/orchestrator ./

# Runtime configuration
ENV HOME=/home/app
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Expose port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

# Start the application
CMD ["bin/orchestrator", "start"]
