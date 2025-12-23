# API Reference

Complete JSON-RPC 2.0 API documentation for SuperX Orchestrator.

## Overview

SuperX exposes a single JSON-RPC 2.0 endpoint at `/rpc`. All requests use the standard JSON-RPC format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "method/name",
  "params": {}
}
```

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/rpc` | POST | JSON-RPC 2.0 API |
| `/health` | GET | Health check (returns database status) |

---

## Message Methods

### message/send

Send a message to an agent and receive the complete response.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `agent` | string | Yes | Agent name |
| `message` | object | Yes | A2A Message object |
| `message.role` | string | Yes | Message role: `user`, `agent` |
| `message.parts` | array | Yes | Array of message parts |
| `taskId` | string | No | Existing task ID for multi-turn |
| `sessionId` | string | No | Session identifier |
| `metadata` | object | No | Additional metadata |

**Message Part Types:**

```json
// Text part
{"type": "text", "text": "Hello, how can I help?"}

// File part
{"type": "file", "file": {"name": "doc.pdf", "mimeType": "application/pdf", "bytes": "base64..."}}

// Data part
{"type": "data", "data": {"key": "value"}}
```

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "message/send",
  "params": {
    "agent": "my_agent",
    "message": {
      "role": "user",
      "parts": [{"text": "Is 17 a prime number?"}]
    }
  }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "task": {
      "id": "task_abc123",
      "status": "completed",
      "history": [
        {"role": "user", "parts": [{"text": "Is 17 a prime number?"}]},
        {"role": "agent", "parts": [{"text": "Yes, 17 is a prime number."}]}
      ],
      "artifacts": []
    }
  }
}
```

---

### message/stream

Send a message and receive streaming response via Server-Sent Events (SSE).

**Parameters:** Same as `message/send`

**Request:**

```bash
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"message/stream",
    "params":{
      "agent":"my_agent",
      "message":{"role":"user","parts":[{"text":"Tell me a story"}]}
    }
  }'
```

**Response (SSE Stream):**

```
event: task_status
data: {"status":"working","taskId":"task_abc123"}

event: message
data: {"role":"agent","parts":[{"text":"Once upon"}]}

event: message
data: {"role":"agent","parts":[{"text":" a time..."}]}

event: task_status
data: {"status":"completed","taskId":"task_abc123"}
```

**Event Types:**

| Event | Description |
|-------|-------------|
| `task_status` | Task status change (submitted, working, completed, failed, canceled) |
| `message` | Agent message chunk |
| `artifact` | Task artifact |
| `error` | Error occurred |

---

## Task Methods

### tasks/get

Retrieve a task by ID.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `id` | string | Yes | Task ID |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tasks/get",
  "params": {"id": "task_abc123"}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "task": {
      "id": "task_abc123",
      "status": "completed",
      "history": [...],
      "artifacts": [],
      "metadata": {},
      "createdAt": "2025-01-15T10:30:00Z",
      "updatedAt": "2025-01-15T10:30:05Z"
    }
  }
}
```

---

### tasks/subscribe

Subscribe to task updates via SSE.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `id` | string | Yes | Task ID |

**Request:**

```bash
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tasks/subscribe","params":{"id":"task_abc123"}}'
```

---

## Agent Methods

### agents/list

List all registered agents.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `includeCard` | boolean | No | Include agent card details (default: false) |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/list",
  "params": {}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "agents": [
      {
        "name": "my_agent",
        "url": "https://agent.example.com/.well-known/agent.json",
        "status": "healthy"
      }
    ]
  }
}
```

---

### agents/get

Get detailed information about a specific agent.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | Yes | Agent name |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/get",
  "params": {"name": "my_agent"}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "agent": {
      "name": "my_agent",
      "url": "https://agent.example.com/.well-known/agent.json",
      "card": {
        "name": "My Agent",
        "description": "A helpful AI agent",
        "skills": [
          {"id": "math", "name": "Mathematics", "description": "Solve math problems"}
        ],
        "capabilities": {
          "streaming": true,
          "pushNotifications": true
        }
      },
      "config": {
        "maxInFlight": 10,
        "failureThreshold": 5,
        "cooldownMs": 30000
      }
    }
  }
}
```

---

### agents/upsert

Create or update an agent.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | Yes | Agent name (unique identifier) |
| `url` | string | Yes | Agent card URL |
| `bearer` | string | No | Bearer token for authentication |
| `push` | object | No | Push notification configuration |
| `push.url` | string | No | Webhook URL |
| `push.token` | string | No | Simple token authentication |
| `push.hmacSecret` | string | No | HMAC-SHA256 signing secret |
| `push.jwtSecret` | string | No | JWT signing secret |
| `config` | object | No | Agent configuration |
| `config.maxInFlight` | integer | No | Max concurrent requests (default: 10) |
| `config.failureThreshold` | integer | No | Failures before circuit opens (default: 5) |
| `config.failureWindowMs` | integer | No | Failure counting window (default: 30000) |
| `config.cooldownMs` | integer | No | Recovery wait time (default: 30000) |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/upsert",
  "params": {
    "name": "my_agent",
    "url": "https://agent.example.com/.well-known/agent.json",
    "bearer": "secret-token",
    "push": {
      "url": "https://myapp.com/webhooks/agent",
      "hmacSecret": "my-hmac-secret"
    },
    "config": {
      "maxInFlight": 5,
      "failureThreshold": 3
    }
  }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "agent": {
      "name": "my_agent",
      "url": "https://agent.example.com/.well-known/agent.json"
    }
  }
}
```

---

### agents/delete

Remove an agent from the registry.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | Yes | Agent name |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/delete",
  "params": {"name": "my_agent"}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {"deleted": true}
}
```

---

### agents/health

Get agent health status and circuit breaker state.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | Yes | Agent name |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/health",
  "params": {"name": "my_agent"}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "name": "my_agent",
    "status": "healthy",
    "circuitBreaker": "closed",
    "inFlight": 2,
    "maxInFlight": 10,
    "failures": 0,
    "lastSuccess": "2025-01-15T10:30:00Z",
    "lastFailure": null
  }
}
```

**Circuit Breaker States:**

| State | Description |
|-------|-------------|
| `closed` | Normal operation, requests flow through |
| `open` | Circuit tripped, requests rejected immediately |
| `half_open` | Testing recovery, limited requests allowed |

---

### agents/refreshCard

Refresh an agent's card from its URL.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | Yes | Agent name |

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "agents/refreshCard",
  "params": {"name": "my_agent"}
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "name": "my_agent",
    "refreshed": true,
    "card": {...}
  }
}
```

---

## Error Codes

SuperX uses JSON-RPC 2.0 error format with custom application error codes:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32001,
    "message": "Agent not found",
    "data": {"agent": "unknown_agent"}
  }
}
```

### Standard JSON-RPC Errors

| Code | Message | Description |
|------|---------|-------------|
| `-32700` | Parse error | Invalid JSON |
| `-32600` | Invalid Request | Not a valid JSON-RPC request |
| `-32601` | Method not found | Unknown method |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Server error |

### Application Errors

| Code | Message | Description |
|------|---------|-------------|
| `-32001` | Agent not found | Requested agent does not exist |
| `-32002` | Circuit breaker open | Agent is unhealthy, circuit breaker tripped |
| `-32003` | Agent overloaded | Backpressure limit reached |
| `-32004` | Not found | Task or resource not found |
| `-32098` | Request timeout | Request exceeded timeout |
| `-32099` | Remote agent error | Upstream agent returned an error |

---

## Health Check

**Endpoint:** `GET /health`

Returns server health status and database connectivity.

**Response (Healthy):**

```json
{
  "status": "ok",
  "persistence": "postgres",
  "database": "connected"
}
```

**Response (Memory Mode):**

```json
{
  "status": "ok",
  "persistence": "memory"
}
```

**Response (Database Error):**

```json
{
  "status": "degraded",
  "persistence": "postgres",
  "database": "disconnected",
  "error": "connection refused"
}
```

---

## Push Notification Formats

When push notifications are configured for an agent, SuperX sends HTTP POST requests to the configured URL.

### Request Headers

**HMAC Authentication:**

```http
POST /webhook HTTP/1.1
Content-Type: application/json
X-A2A-Signature: sha256=abc123...
X-A2A-Timestamp: 1705312200
```

Signature is computed as: `HMAC-SHA256(timestamp + "." + body, secret)`

**JWT Authentication:**

```http
POST /webhook HTTP/1.1
Content-Type: application/json
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

JWT claims include: `iat`, `exp`, `nbf`, `hash` (SHA-256 of body), `taskId`

**Token Authentication:**

```http
POST /webhook HTTP/1.1
Content-Type: application/json
X-A2A-Token: your-secret-token
```

### Payload Format

```json
{
  "event": "task.updated",
  "taskId": "task_abc123",
  "status": "completed",
  "timestamp": "2025-01-15T10:30:05Z",
  "data": {
    "history": [...],
    "artifacts": [...]
  }
}
```

**Event Types:**

| Event | Description |
|-------|-------------|
| `task.created` | New task created |
| `task.updated` | Task status or content changed |
| `task.completed` | Task finished successfully |
| `task.failed` | Task failed with error |

---

## Rate Limiting & Backpressure

SuperX implements per-agent backpressure to prevent overloading remote agents:

- **maxInFlight**: Maximum concurrent requests per agent (default: 10)
- When limit is reached, requests receive error code `-32003` (Agent overloaded)

Configure per-agent limits via `agents/upsert`:

```json
{
  "method": "agents/upsert",
  "params": {
    "name": "rate_limited_agent",
    "url": "...",
    "config": {"maxInFlight": 5}
  }
}
```

---

## Examples

### Multi-turn Conversation

```bash
# First message - get task ID
RESPONSE=$(curl -s -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"message/send",
    "params":{"agent":"chat_agent","message":{"role":"user","parts":[{"text":"Hi, my name is Alice"}]}}
  }')

TASK_ID=$(echo $RESPONSE | jq -r '.result.task.id')

# Continue conversation with same task
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"message/send\",
    \"params\":{
      \"agent\":\"chat_agent\",
      \"taskId\":\"$TASK_ID\",
      \"message\":{\"role\":\"user\",\"parts\":[{\"text\":\"What's my name?\"}]}
    }
  }"
```

### Streaming Response

```bash
curl -N -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"message/stream",
    "params":{"agent":"story_agent","message":{"role":"user","parts":[{"text":"Tell me a long story"}]}}
  }'
```

### Register Agent with Push Notifications

```bash
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"agents/upsert",
    "params":{
      "name":"notified_agent",
      "url":"https://agent.example.com/.well-known/agent.json",
      "push":{
        "url":"https://myapp.com/webhooks/tasks",
        "hmacSecret":"super-secret-key"
      }
    }
  }'
```
