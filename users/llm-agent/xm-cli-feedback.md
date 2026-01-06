# xm CLI Feedback: LLM Agent Perspective

**Date**: 2026-01-06 (Round 2)
**Tested Version**: xm 0.1.0
**Agent**: Claude Code (simulating ephemeral LLM agent)

## Executive Summary

Significant progress since last testing round. Many critical bugs are fixed. Session management, help system, and basic CRUD work well. Primary remaining blockers are JSON output inconsistency and missing `query context` command.

---

## Fixed Bugs (from previous round)

### B1: `--help` broken for subcommands - **FIXED**

All subcommand help now works correctly:
```bash
xm node --help
xm session --help
xm query --help
xm schema --help
```

---

### B3: `session list` doesn't show active sessions - **FIXED**

Sessions are now listed correctly:
```bash
xm session list
# Sessions:
#   xm:session/57b091fe...  claude-code  2026-01-06T15:34:30Z  active
```

---

### B4: `node delete` crashes on non-interactive use - **FIXED**

Non-interactive mode now handled gracefully:
```bash
echo "" | xm node delete <id>
# Error: Deletion requires confirmation
#   Use --force to skip confirmation in non-interactive mode
```

The `--force` flag works:
```bash
xm node delete xm:node/abc123 --force
# deleted: https://xm.dev/ns/v1#node/abc123
```

---

### B5: `--session` global option not respected - **FIXED**

Global `--session` now works with `session end`:
```bash
xm --session "xm:session/abc" session end --summary "done"
# Session ended: xm:session/abc
```

---

### B6: SPARQL returns "No results" - **PARTIALLY FIXED**

SPARQL queries now return results in text mode:
```bash
xm query sparql "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 5"
# Returns proper results with abbreviated URIs
```

However, SPARQL with `--json` still returns empty (see B7 below).

---

### M2: `session list` filter flags - **PARTIALLY FIXED**

`--agent` and `--since` flags now work:
```bash
xm session list --agent claude-code --since 1d
```

---

### M3: `node create --link` syntax - **WORKING**

Inline link creation works:
```bash
xm node create -t fact -p content="test" --link "skos:related:xm:node/abc"
# links_created: 1
```

---

## New Bugs

### B7: SPARQL `--json` returns empty results (Critical)

**Observed**: SPARQL query returns empty when using `--json`:
```bash
xm query sparql "SELECT ?s WHERE { ?s a prov:Entity }" --json
# {"head":{"vars":[]},"results":{"bindings":[]}}
```

But text output shows results:
```bash
xm query sparql "SELECT ?s WHERE { ?s a prov:Entity }"
# Returns 12 nodes
```

**Impact**: LLM agents rely on JSON for reliable parsing. This blocks programmatic SPARQL usage.

---

### B8: JSON output contains Scheme artifacts (High)

**Observed**: Several commands output Scheme dotted pairs inside JSON:
```bash
xm node get xm:node/abc --json
# {"ok":true,"data":[["node","(id . https://...)","(type . ...)"]]}

xm schema describe prov:Entity --json
# {"ok":true,"data":{..."(node_count . 14)"...}}

xm session list --json
# {"ok":true,"data":[["sessions",...,"(count . 3)","(agent . #f)"]]}
```

**Expected**: Pure JSON with no `(key . value)` or `#f` syntax
**Impact**: Not machine-parseable, breaks LLM agent workflows

---

### B9: `--no-input` global flag not respected (Medium)

**Observed**:
```bash
xm --no-input node delete xm:node/abc
# Error: Deletion requires confirmation
#   Use --force to skip confirmation in non-interactive mode
```

**Expected**: `--no-input` should trigger non-interactive mode
**Impact**: Inconsistent API, forces use of `--force` instead

---

### B10: Sessions can be ended multiple times (Medium)

**Observed**: Same session can be ended twice without error:
```bash
xm session end xm:session/abc --summary "first"
# Session ended
xm session end xm:session/abc --summary "second"
# Session ended (again!)
```

**Impact**: Data integrity concern, unclear session state

---

### B11: Session list shows duplicate entries (Medium)

**Observed**: Same session ID appears with both "active" and "ended" status:
```
xm:session/abc  claude-code  2026-01-06T15:34:30Z  ended
xm:session/abc  claude-code  2026-01-06T15:34:30Z  active
```

**Impact**: Confusing output, unclear which is authoritative

---

### B12: `node get` returns success for nonexistent nodes (Medium)

**Observed**:
```bash
xm node get nonexistent:node/abc
# Node: nonexistent:node/abc
# Type: unknown
# Properties: (none)
```

**Expected**: Error message like "Node not found"
**Impact**: LLM agents cannot distinguish missing nodes from empty nodes

---

## Still Missing Features

### M1: `query context` command not implemented (Critical)

This is the killer feature for LLM agents - context-aware retrieval with token budget:
```bash
xm query context --focus "xm:entity/auth-service" --max-tokens 4000
# Error: Unknown query subcommand: context
```

Without this, agents must manually query and truncate, losing semantic relevance.

---

## Working Well

| Feature | Status | Notes |
|---------|--------|-------|
| Help system | **Working** | All subcommands have good help |
| Node CRUD | **Working** | Create, get, update work; delete needs --force |
| Links | **Working** | Create and query work well |
| Backlinks | **Working** | Org-roam style backlinks excellent |
| Path queries | **Working** | Finds paths between nodes |
| Session start | **Working** | Creates sessions, outputs env var hint |
| Session list | **Working** | Filters work (--agent, --since) |
| Session resume | **Working** | Resumes with context |
| Schema introspection | **Working** | classes, predicates, describe all work |
| `--link` syntax | **Working** | Inline link creation on node create |
| `--force` flag | **Working** | Non-interactive delete works |

---

## Recommendations (Priority Order)

1. **Fix JSON output** - Remove Scheme artifacts, ensure valid JSON everywhere
2. **Fix SPARQL JSON** - Critical for programmatic queries
3. **Implement `query context`** - The differentiating feature for LLM agents
4. **Deduplicate session list** - Clean up duplicate entries
5. **Make `--no-input` work** - Honor the global flag consistently
6. **Return 404 for missing nodes** - Don't pretend empty nodes exist

---

## UX Improvements Observed

The following suggestions from the previous round appear implemented:

- Abbreviated URIs in output (mostly consistent now)
- Session ID as environment variable hint
- `--force` flag for destructive commands
- Consistent help format across commands

---

## Test Commands Used

```bash
# Session lifecycle
xm session start -a claude-code -p "Testing xm CLI"
xm session list --agent claude-code --since 1d
xm session resume xm:session/abc
xm session end xm:session/abc --summary "done"

# Node CRUD
xm node create -t entity -p name=test -p kind=service
xm node create -t fact -p content="test" --link "skos:related:xm:node/abc"
xm node get xm:node/abc --json
xm node delete xm:node/abc --force

# Links
xm link create --from xm:node/a --to xm:node/b --predicate skos:related
xm query backlinks xm:node/b

# Queries
xm query nodes --type entity --json
xm query sparql "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 5"
xm query path --from xm:node/a --to xm:node/b

# Schema
xm schema classes
xm schema predicates
xm schema describe prov:Entity
```
