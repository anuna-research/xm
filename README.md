# xm

Shared memory infrastructure for heterogeneous LLM agents.

## Overview

xm is a research project exploring how LLM agents (Claude, GPT, Gemini, local models) can share persistent, linked memory. The core component is **xm** (Cross Memory), a CLI tool that any agent can use to store and retrieve knowledge.

## Use Cases

### Cross-Agent Memory

Claude Code debugs an API, GPT-4 reviews the fix later:

```bash
# Claude Code stores what it learned
xm node create -t fact -p content="Auth bug was in token refresh logic" \
  -p source="claude-code" -p context="debugging session 2024-01-15"

# GPT-4 queries for context before code review
xm query nodes --type fact --filter "source=claude-code"
```

### Long-Term User Preferences

Agents remember user preferences across sessions:

```bash
# Store preference
xm node create -t preference -p user="hugo" \
  -p content="Prefers functional programming style"

# Any agent can query later
xm query sparql "SELECT ?pref WHERE { ?s a xm:preference ; xm:content ?pref }"
```

### Project Knowledge Graph

Build linked knowledge about a codebase:

```bash
# Create entities
xm node create -t entity -p name="auth-service" -p kind="microservice"
xm node create -t entity -p name="user-db" -p kind="database"

# Link them
xm link create auth-service user-db -t "depends-on"

# Discover relationships via backlinks
xm query backlinks user-db
```

### Capability-Controlled Sharing

Share read-only access to specific knowledge:

```bash
# Create attenuated capability (read-only, expires in 7 days)
xm cap attenuate root-cap --permissions read --ttl 7d

# Export as sturdyref for another agent
xm cap export cap-123 --format sturdyref
```

## Components

```
meld/
├── xm/                    # Cross Memory CLI tool
├── SPEC-029-*.md          # xm specification
└── users/                 # User personas and scenarios
```

See [xm/README.md](xm/README.md) for installation and full command reference.

## License

AGPL-3.0-or-later

Copyright 2026 Hugo O'Connor, Anuna Research
