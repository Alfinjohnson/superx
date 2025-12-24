# Agent Cards - Technical Deep Dive

Agent Cards are discovery documents that describe an agent's capabilities, enabling clients to understand what an agent can do before interacting with it.

---

## Overview

An Agent Card is analogous to:
- `/.well-known/openid-configuration` in OAuth/OIDC
- `openapi.json` for REST APIs
- Service discovery in microservices

### Location

```
https://agent.example.com/.well-known/agent.json      # A2A native
https://superx.local/agents/{id}/.well-known/agent-card.json  # SuperX proxy
```

---

## Agent Card Schema

```json
{
  "name": "my_agent",
  "version": "1.0.0",
  "description": "Human-readable description of the agent",
  "url": "https://agent.example.com/a2a",
  "protocol": "a2a",
  "protocolVersion": "0.3.0",
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "stateTransitionHistory": false
  },
  "defaultInputModes": ["text/plain", "application/json"],
  "defaultOutputModes": ["application/json", "text/plain"],
  "skills": [
    {
      "id": "skill_id",
      "name": "Skill Name",
      "description": "What this skill does",
      "tags": ["category", "type"],
      "inputSchema": { /* JSON Schema */ },
      "outputSchema": { /* JSON Schema */ }
    }
  ],
  "authentication": {
    "schemes": ["bearer", "api_key"]
  }
}
```

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Unique identifier for the agent |
| `description` | string | Human-readable description |
| `url` | string | Endpoint for agent communication |
| `protocol` | string | Protocol type (`a2a`, `mcp`) |
| `protocolVersion` | string | Protocol version (`0.3.0`, `2024-11-05`) |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Agent version |
| `capabilities` | object | Feature flags (streaming, push, etc.) |
| `skills` | array | List of agent capabilities |
| `authentication` | object | Auth requirements |
| `defaultInputModes` | array | Accepted MIME types |
| `defaultOutputModes` | array | Response MIME types |

---

## How SuperX Handles Agent Cards

SuperX proxies agent cards through a unified endpoint, handling both A2A and MCP protocols transparently.

### Endpoint

```
GET /agents/{agent_id}/.well-known/agent-card.json
```

### Request Flow

```
┌────────┐     ┌─────────────────────────────────────────────────────┐
│ Client │────>│                     SuperX                          │
└────────┘     │                                                     │
               │  ┌─────────────────────────────────────────────┐   │
               │  │            AgentCard.serve/2                 │   │
               │  │                                              │   │
               │  │  1. Lookup agent in store                    │   │
               │  │  2. Check protocol type                      │   │
               │  │                                              │   │
               │  │     ┌─────────────┐    ┌─────────────┐      │   │
               │  │     │  A2A Agent  │    │  MCP Agent  │      │   │
               │  │     └──────┬──────┘    └──────┬──────┘      │   │
               │  │            │                  │              │   │
               │  │            ▼                  ▼              │   │
               │  │     Fetch from         Synthesize from      │   │
               │  │     remote URL         session state        │   │
               │  │                                              │   │
               │  └─────────────────────────────────────────────┘   │
               └─────────────────────────────────────────────────────┘
```

---

## A2A Protocol: Fetching Agent Cards

For A2A agents, SuperX fetches the card from the remote agent's well-known endpoint.

### Flow

```
Client                     SuperX                        A2A Agent
  │                          │                              │
  │── GET /agents/my_agent/  │                              │
  │   .well-known/agent-card │                              │
  │                          │                              │
  │                          │── GET /.well-known/agent.json│
  │                          │<─────────── Agent Card ──────│
  │                          │                              │
  │                          │   Transform URLs             │
  │                          │   (proxy through SuperX)     │
  │                          │                              │
  │<──── Proxied Card ───────│                              │
```

### Code Path

```elixir
# lib/orchestrator/web/agent_card.ex

def serve(conn, agent_id) do
  case AgentStore.get(agent_id) do
    nil ->
      not_found(conn, agent_id)
    
    %{"protocol" => "a2a"} = agent ->
      serve_a2a_card(conn, agent_id, agent)
    
    %{"protocol" => "mcp"} = agent ->
      serve_mcp_card(conn, agent_id, agent)
  end
end

defp serve_a2a_card(conn, agent_id, agent) do
  card_url = get_card_url(agent)
  
  case HttpClient.get(card_url) do
    {:ok, %{status: 200, body: card}} ->
      # Transform URLs to proxy through SuperX
      proxied_card = transform_card_urls(card, agent_id)
      json_response(conn, 200, proxied_card)
    
    {:error, reason} ->
      error_response(conn, 502, "Failed to reach agent: #{reason}")
  end
end
```

### URL Transformation

SuperX rewrites URLs in the card to route through the gateway:

```json
// Original from agent
{
  "url": "http://internal-agent:8001/a2a",
  "agentCard": {
    "url": "http://internal-agent:8001/.well-known/agent.json"
  }
}

// Transformed by SuperX
{
  "url": "http://superx.local:4000/agents/my_agent",
  "agentCard": {
    "url": "http://superx.local:4000/agents/my_agent/.well-known/agent-card.json"
  }
}
```

---

## MCP Protocol: Synthesizing Agent Cards

MCP servers don't have a native agent card concept. SuperX synthesizes one from the MCP server's capabilities discovered during the `initialize` handshake.

### Flow

```
Client                     SuperX                        MCP Server
  │                          │                              │
  │                          │══ Session already active ════│
  │                          │   (tools, resources cached)  │
  │                          │                              │
  │── GET /agents/exa/       │                              │
  │   .well-known/agent-card │                              │
  │                          │                              │
  │                          │   Build card from            │
  │                          │   session.tools              │
  │                          │   session.resources          │
  │                          │   session.prompts            │
  │                          │                              │
  │<── Synthesized Card ─────│                              │
```

### Data Sources

| Card Field | MCP Source |
|------------|------------|
| `name` | Server ID from config |
| `description` | `serverInfo.name` from `initialize` response |
| `capabilities` | `capabilities` from `initialize` response |
| `skills` | `tools/list` response |
| `resources` | `resources/list` response (if supported) |
| `prompts` | `prompts/list` response (if supported) |

### Code Path

```elixir
# lib/orchestrator/mcp/session.ex

def handle_call(:get_agent_card, _from, state) do
  card = build_agent_card(state)
  {:reply, {:ok, card}, state}
end

defp build_agent_card(state) do
  %{
    "name" => state.server_id,
    "protocol" => "mcp",
    "protocolVersion" => "2024-11-05",
    "description" => get_in(state.server_info, ["name"]) || state.server_id,
    "version" => get_in(state.server_info, ["version"]),
    "capabilities" => %{
      "tools" => state.capabilities["tools"],
      "resources" => state.capabilities["resources"],
      "prompts" => state.capabilities["prompts"],
      "sampling" => state.capabilities["sampling"]
    },
    "skills" => build_skills_from_tools(state.tools),
    "resources" => build_resource_list(state.resources),
    "prompts" => build_prompt_list(state.prompts)
  }
end

defp build_skills_from_tools(nil), do: []
defp build_skills_from_tools(tools) do
  Enum.map(tools, fn tool ->
    %{
      "id" => tool["name"],
      "name" => tool["name"],
      "description" => tool["description"],
      "inputSchema" => tool["inputSchema"]
    }
  end)
end
```

### Example: Exa Search MCP Server

**MCP `initialize` response:**
```json
{
  "protocolVersion": "2024-11-05",
  "serverInfo": {
    "name": "Exa MCP Server",
    "version": "1.0.0"
  },
  "capabilities": {
    "tools": { "listChanged": true }
  }
}
```

**MCP `tools/list` response:**
```json
{
  "tools": [
    {
      "name": "search",
      "description": "Search the web using Exa AI",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" },
          "numResults": { "type": "integer", "default": 10 }
        },
        "required": ["query"]
      }
    },
    {
      "name": "get_contents",
      "description": "Get full contents of URLs",
      "inputSchema": {
        "type": "object",
        "properties": {
          "urls": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["urls"]
      }
    }
  ]
}
```

**Synthesized Agent Card:**
```json
{
  "name": "exa_search",
  "protocol": "mcp",
  "protocolVersion": "2024-11-05",
  "description": "Exa MCP Server",
  "version": "1.0.0",
  "capabilities": {
    "tools": { "listChanged": true },
    "resources": null,
    "prompts": null,
    "sampling": null
  },
  "skills": [
    {
      "id": "search",
      "name": "search",
      "description": "Search the web using Exa AI",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search query" },
          "numResults": { "type": "integer", "default": 10 }
        },
        "required": ["query"]
      }
    },
    {
      "id": "get_contents",
      "name": "get_contents",
      "description": "Get full contents of URLs",
      "inputSchema": {
        "type": "object",
        "properties": {
          "urls": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["urls"]
      }
    }
  ]
}
```

---

## Comparison: A2A vs MCP Agent Cards

| Aspect | A2A | MCP |
|--------|-----|-----|
| **Source** | Remote `/.well-known/agent.json` | Synthesized from session state |
| **When Available** | After HTTP fetch | After `initialize` handshake |
| **Skills Definition** | Agent author defines | Auto-generated from `tools/list` |
| **Caching** | Optional (TTL-based) | Always cached in session |
| **Update Mechanism** | Refresh on demand | `notifications/tools_changed` |
| **Authentication Info** | Included in card | Not available (transport-level) |

---

## Caching Strategy

### A2A Cards

```elixir
# Cached in Agent.Worker state
%{
  agent_card: %{...},
  card_fetched_at: ~U[2024-12-24 10:00:00Z],
  card_ttl: 300_000  # 5 minutes
}
```

- **TTL**: 5 minutes default
- **Refresh**: On demand via `agents/refreshCard` RPC method
- **Invalidation**: On agent config update

### MCP Cards

```elixir
# Cached in MCP.Session state
%{
  tools: [...],      # Cached after tools/list
  resources: [...],  # Cached after resources/list
  prompts: [...],    # Cached after prompts/list
  capabilities: %{}  # From initialize response
}
```

- **TTL**: Indefinite (session lifetime)
- **Refresh**: On `notifications/tools_list_changed` from server
- **Invalidation**: On session reconnect

---

## Error Handling

### A2A Errors

| Scenario | Response |
|----------|----------|
| Agent not found | 404 Not Found |
| Remote unreachable | 502 Bad Gateway |
| Invalid card format | 502 Bad Gateway |
| Timeout | 504 Gateway Timeout |

### MCP Errors

| Scenario | Response |
|----------|----------|
| Agent not found | 404 Not Found |
| Session not started | 503 Service Unavailable |
| Session not ready | 503 Service Unavailable |
| Session crashed | 503 Service Unavailable |

---

## Usage Examples

### Fetch Agent Card via cURL

```bash
# Get card for any agent (A2A or MCP)
curl http://localhost:4000/agents/my_agent/.well-known/agent-card.json
```

### Fetch via RPC

```bash
curl -X POST http://localhost:4000/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "agents/get",
    "params": { "id": "my_agent" }
  }'
```

### Programmatic Access (Elixir)

```elixir
# Get agent with card
{:ok, agent} = Orchestrator.Agent.Store.get("my_agent")

# For MCP, get synthesized card
{:ok, session} = Orchestrator.MCP.Supervisor.lookup_session("my_agent")
{:ok, card} = Orchestrator.MCP.Session.get_agent_card(session)
```

---

## Related Documentation

- [A2A Protocol Specification](https://google.github.io/A2A/)
- [MCP Protocol Specification](https://spec.modelcontextprotocol.io/)
- [SuperX Agent Configuration](../samples/agents.yml)

---

*Last updated: December 24, 2025*
