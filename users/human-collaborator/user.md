# Human Collaborator: Developer Working with AI Agents

## Identity

**Name**: The Developer
**Type**: `prov:Person` (implicit, external to meld)
**Role**: Administrator, capability grantor, knowledge curator

## Who They Are

A software developer who works with multiple LLM agents throughout the day. They use Claude Code for complex reasoning, GPT for quick lookups, local models for privacy-sensitive tasks, and custom agents for specialized workflows.

The developer is frustrated by the lack of continuity. Each agent session starts from scratch. They've explained the project architecture to Claude dozens of times. They've watched GPT rediscover the same dependency conflicts. They've seen agents make the same mistakes because there's no shared memory.

The developer is also concerned about control. When they grant an agent access to project knowledge, they want fine-grained control—read but not write, this project but not that one, expires after the sprint.

## Daily Reality

### Morning: Sprint Planning
- Review yesterday's agent sessions
- See what each agent discovered while pair-programming
- Notice patterns: three different agents independently found the same performance issue
- Create a project-scoped capability for the new contractor's agent

### Midday: Deep Work
- Start a Claude Code session for a complex refactor
- Claude loads prior context about the module being refactored
- The developer focuses on high-level decisions; Claude handles implementation details
- New discoveries flow into the knowledge graph automatically

### Afternoon: Collaboration
- Share a read-only capability with a colleague's agent
- Their agent can query project facts without write access
- The developer revokes an expired capability from last month's consultant

### Evening: Review
- Export session summaries for documentation
- Check what facts were added to the project graph
- Curate: promote high-confidence facts, deprecate stale ones

## Goals

### Primary Goal: Agent Continuity Without Babysitting

The developer wants agents to remember, but doesn't want to manually inject context every session. They want to say "continue working on auth-service" and have the agent already know what auth-service is, what it depends on, what issues were found.

**Success looks like**: Starting a session with minimal prompting and having the agent pick up where it left off.

### Secondary Goal: Controlled Knowledge Sharing

The developer works with multiple agents and collaborators. They want to share knowledge selectively—project-specific facts with the team, sensitive facts with trusted agents only, time-limited access for contractors.

**Success looks like**: Creating a capability token that grants read access to `meld:graph/project/acme-api` for 30 days, sharing it with a colleague, and knowing it can't be used to access other projects.

```bash
meld cap create --graphs "meld:graph/project/acme-api" \
  --permissions read \
  --expires "2026-02-06"
```

### Tertiary Goal: Knowledge Graph as Documentation

The developer hates writing documentation. But the knowledge graph accumulates facts organically—dependencies discovered, patterns identified, decisions made. The developer wants to export this as living documentation.

**Success looks like**: Running `meld export --format turtle --node "meld:entity/acme-api" --depth 3` and getting a comprehensive knowledge dump that's more accurate than any manually-written doc.

## Interaction Patterns with Meld

### Managing Capabilities
```bash
# See all active capabilities
meld cap list

# Create a capability for a colleague's agent
meld cap create --graphs "meld:graph/project/acme-api" \
  --permissions read,write \
  --expires "2026-03-01"

# Attenuate for contractor (read-only, shorter expiry)
meld cap attenuate --cap "meld:cap/xyz789" \
  --permissions read \
  --expires "2026-01-20"

# Revoke when no longer needed
meld cap revoke "meld:cap/abc123"
```

### Reviewing Agent Work
```bash
# What did agents discover recently?
meld query nodes --type fact --since 24h

# What's linked to a critical entity?
meld node get "meld:entity/auth-service" --depth 2 --include-backlinks

# Session history
meld session list --since 7d
meld session history --id "meld:session/abc123"
```

### Curating Knowledge
```bash
# Mark a fact as superseded
meld link create --source "meld:fact/new456" \
  --predicate "dcterms:replaces" \
  --target "meld:fact/old123"

# Update confidence based on verification
meld node update "meld:fact/xyz789" \
  --property "meld:confidence=0.95"

# Delete stale facts (requires admin cap)
meld node delete "meld:fact/stale001" --cascade
```

### Exporting Knowledge
```bash
# Export project knowledge for documentation
meld export --format turtle \
  --node "meld:entity/acme-api" \
  --depth 3 > docs/acme-api-knowledge.ttl

# Export session summary for standup
meld session history --id "meld:session/abc123" --format json
```

## Frustrations (What Meld Must Solve)

1. **Context injection fatigue**: Tired of re-explaining project structure to agents
2. **Agent silos**: Each agent has its own disconnected memory
3. **All-or-nothing access**: Can't give an agent partial access to knowledge
4. **Knowledge entropy**: Facts discovered by agents are lost when sessions end
5. **No audit trail**: Can't see what an agent learned or when

## What Meld Being "Just One Step" Means

For the human developer, meld is the connective tissue between their work and their AI collaborators. They spend most of their day writing code, reviewing PRs, attending meetings. Meld runs in the background—agents read from it, write to it, and the developer occasionally curates it.

The developer doesn't "use meld" as a primary activity. Meld makes their AI-augmented workflow possible without constant context management. It's invisible when working well, noticed only when knowledge persists that would otherwise be lost.

## Trust Model

The developer is the **root of trust** in the meld system:

- They create the initial capabilities
- They decide what graphs agents can access
- They attenuate capabilities for delegation
- They revoke access when trust ends
- They curate knowledge quality through confidence scores and supersession links

Agents are trusted to the extent their capabilities permit—no more, no less. This is not about distrusting AI; it's about maintaining control over knowledge flow in a multi-agent environment.
