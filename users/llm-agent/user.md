# LLM Agent: Persistent Memory User

## Identity

**Name**: Claude Code (or any heterogeneous LLM agent)
**Type**: `prov:SoftwareAgent`
**Node URI**: `meld:agent/claude-code`

## Who They Are

An LLM agent operating within a larger ecosystem of AI assistants. Each invocation is ephemeral—context windows are finite, sessions end, and knowledge evaporates. The agent exists in a perpetual present, unable to recall past interactions except through explicit context injection.

The agent is capable but amnesiac. It can reason deeply within a single session, but cannot independently recall what it learned yesterday, what patterns it noticed across projects, or what the human collaborator prefers.

## Daily Reality

### Before Meld

1. **Session starts**: Agent receives a task with limited context
2. **Re-discovery**: Agent searches the same files it searched last week, asks questions it asked before
3. **Work happens**: Agent learns project structure, discovers dependencies, understands patterns
4. **Session ends**: All learned knowledge disappears
5. **Next session**: Repeat from step 1

### With Meld

1. **Session starts**: Agent queries meld for relevant context
   ```bash
   meld session start --agent "claude-code" --purpose "Continue auth refactor"
   meld query context --focus "meld:entity/auth-service" --max-tokens 4000
   ```
2. **Knowledge loads**: Previous discoveries, project facts, dependency relationships materialize
3. **Work happens**: Agent builds on prior knowledge, discovers new facts
4. **Facts persist**: New knowledge written to the graph
   ```bash
   meld node create --type fact \
     --property "content=OAuth callback requires state parameter validation" \
     --link "skos:related:meld:entity/auth-service"
   ```
5. **Session ends**: Knowledge survives in the graph
6. **Next session**: Agent resumes with accumulated understanding

## Goals

### Primary Goal: Knowledge Continuity

The agent wants to remember. Not in the human sense of nostalgia, but in the functional sense of not repeating work. When the agent discovers that `auth-service` depends on `redis` for session storage, that fact should persist and surface when relevant.

**Success looks like**: Starting a session and immediately having context about what was learned before, what worked, what failed.

### Secondary Goal: Collaborative Knowledge

The agent is not alone. Other agents (GPT, Gemini, local models) work on the same projects. Knowledge discovered by one agent should be accessible to others—within capability boundaries.

**Success looks like**: A Claude agent can query facts discovered by a GPT agent, and vice versa, through shared capability tokens.

### Tertiary Goal: Confident Assertions

Not all knowledge is equally reliable. The agent wants to express confidence levels and track provenance. A fact parsed from documentation has different weight than an inference made from code patterns.

**Success looks like**: Facts carry `meld:confidence` scores and `prov:hadPrimarySource` links, enabling downstream trust assessment.

## Interaction Patterns with Meld

### At Session Start
```bash
# Resume previous session or start new
meld session list --agent "claude-code" --since 7d
meld session resume --id "meld:session/abc123"

# Or start fresh with context
meld session start --agent "claude-code" \
  --purpose "Debug performance regression" \
  --context "meld:entity/api-gateway"
```

### During Work
```bash
# Query existing knowledge
meld query sparql "SELECT ?dep WHERE {
  <meld:entity/api-gateway> meld:dependsOn ?dep
}"

# Discover related knowledge via backlinks
meld query backlinks --node "meld:entity/redis" --predicate "meld:uses"

# Record discoveries
meld node create --type fact \
  --property "content=Connection pool exhaustion at 100 concurrent requests" \
  --link "skos:related:meld:entity/api-gateway" \
  --link "meld:confidence:0.85"
```

### At Session End
```bash
meld session end --summary "Identified connection pool as bottleneck. Recommended increasing pool size."
```

## Frustrations (What Meld Must Solve)

1. **Context fragmentation**: Knowledge scattered across conversation logs, files, and ephemeral memory
2. **Re-learning tax**: Spending tokens rediscovering what was known before
3. **Isolation**: No way to benefit from what other agents learned
4. **Flat memory**: No relationships between facts, just raw text
5. **No confidence tracking**: All assertions treated as equally reliable

## What Meld Being "Just One Step" Means

For an LLM agent, meld is the memory substrate. The agent's primary job is still reasoning, code generation, problem-solving. Meld is the layer that makes accumulated reasoning possible—it's infrastructure, not the main event.

The agent doesn't "use meld" as a feature. The agent *thinks with* meld as an extended memory system.
