# Happy Path: Resume Session with Context

## Scenario

An LLM agent starts a new session to continue work on a project it worked on previously.

## Preconditions

- Agent has a valid capability for the project graph
- Previous session exists with discoveries
- Project entity exists in meld

## Flow

```bash
# 1. Agent checks for recent sessions on this project
meld session list --agent "claude-code" --since 7d

# Response:
{
  "ok": true,
  "data": {
    "sessions": [
      {
        "id": "meld:session/abc123",
        "purpose": "Investigate auth bug",
        "started_at": "2026-01-05T14:30:00Z",
        "ended_at": "2026-01-05T16:45:00Z",
        "nodes_created": 5
      }
    ]
  }
}

# 2. Agent resumes the session
meld session resume --id "meld:session/abc123"

# Response:
{
  "ok": true,
  "data": {
    "session_id": "meld:session/abc123",
    "resumed_at": "2026-01-06T09:00:00Z",
    "context_nodes": 3,
    "prior_discoveries": 5
  }
}

# 3. Agent queries for context around the focus entity
meld query context --focus "meld:entity/auth-service" --max-tokens 4000

# Response:
{
  "ok": true,
  "data": {
    "focus": "meld:entity/auth-service",
    "token_budget": {"max": 4000, "used": 2847},
    "nodes": [
      {
        "id": "meld:entity/auth-service",
        "type": "entity",
        "properties": {"name": "auth-service", "kind": "microservice"}
      },
      {
        "id": "meld:fact/xyz001",
        "type": "fact",
        "properties": {"content": "OAuth callback URL is /auth/callback"},
        "confidence": 0.95
      },
      {
        "id": "meld:fact/xyz002",
        "type": "fact",
        "properties": {"content": "Session storage uses Redis with 24h TTL"},
        "confidence": 0.90
      }
    ],
    "summary": "Microservice with 5 facts, 2 dependencies"
  }
}

# 4. Agent now has context and can continue work
# ... agent performs tasks ...

# 5. Agent discovers new fact and records it
meld node create --type fact \
  --property "content=State parameter missing from OAuth flow causes CSRF vulnerability" \
  --link "skos:related:meld:entity/auth-service" \
  --link "meld:confidence:0.95"

# Response:
{
  "ok": true,
  "data": {
    "id": "meld:node/def456",
    "type": "fact",
    "created_at": "2026-01-06T09:15:00Z",
    "links_created": 2
  }
}

# 6. Agent ends session with summary
meld session end --summary "Found CSRF vulnerability in OAuth flow. State parameter validation missing."

# Response:
{
  "ok": true,
  "data": {
    "session_id": "meld:session/abc123",
    "duration_seconds": 1800,
    "nodes_created": 1,
    "links_created": 3,
    "summary": "Found CSRF vulnerability in OAuth flow. State parameter validation missing."
  }
}
```

## Postconditions

- Session resumed and later ended cleanly
- New fact persisted with provenance linking to session
- Future sessions can query this fact
- Other agents with appropriate capabilities can access this discovery

## What the Agent Gained

- Loaded 2847 tokens of relevant context without re-discovery
- Built on prior knowledge instead of starting from scratch
- Contributed new knowledge that persists beyond session
