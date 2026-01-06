# xm — Cross Memory

Linked memory for LLM agents. A CLI tool for managing persistent, linked memory across heterogeneous LLM agents.

## Overview

**xm** (Cross Memory) provides:

- **Linked Data Memory**: Knowledge stored as semantic triples following RDF principles
- **Capability-Based Access**: Fine-grained permissions using Goblins' object-capability model
- **Bidirectional Links**: Org-roam-inspired backlinks revealing knowledge relationships
- **Agent-Agnostic Interface**: JSON-over-stdout CLI protocol usable by any LLM agent
- **Distributed by Design**: OCapN-based architecture for secure cross-machine agent collaboration

## Architecture

```
┌────────────────────────────────────────────────────┐
│              Heterogeneous LLM Agents              │
│  Claude Code │ GPT-4 │ Gemini │ Local LLaMA │ ... │
└──────────────────────┬─────────────────────────────┘
                       │ CLI or OCapN
┌──────────────────────┼─────────────────────────────┐
│              OCapN Network Layer (CapTP)           │
│  Encrypted channels, sturdyref resolution          │
└──────────────────────┼─────────────────────────────┘
                       │
┌──────────────────────┼─────────────────────────────┐
│         Guile Goblins Runtime (Security Layer)     │
│  Graph Gatekeeper, Capability Store, Sessions      │
└──────────────────────┼─────────────────────────────┘
                       │
┌──────────────────────┼─────────────────────────────┐
│         Oxigraph (Storage Layer via FFI)           │
│  SPARQL 1.1, RDF quads, RocksDB backend           │
└────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build the Rust FFI library
cd xm
cargo build --release

# Make xm available
export PATH="$PWD/bin:$PATH"

# Show help
xm --help

# Create a knowledge node
xm node create -t entity -p name=acme-api -p kind=repository

# Query with SPARQL
xm query sparql "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10"

# Find backlinks (Org-roam style)
xm query backlinks xm:entity/fastapi

# Start an agent session
xm session start -a claude-code -p "Debug auth bug"
```

## Project Structure

```
xm/
├── Cargo.toml               # Rust workspace
├── oxigraph-ffi/            # Rust FFI crate for Oxigraph
│   ├── src/lib.rs           # C ABI exports
│   └── cbindgen.toml        # Header generation
├── guile/                   # Guile Scheme modules
│   └── xm/
│       ├── main.scm         # CLI entry point
│       ├── store.scm        # Oxigraph FFI bindings
│       ├── gatekeeper.scm   # Graph Gatekeeper actor
│       ├── capability.scm   # Capability management
│       ├── session.scm      # Session management
│       ├── journal.scm      # Event journal
│       ├── sync.scm         # Pubsub & synchronization
│       ├── vocabulary.scm   # RDF namespace prefixes
│       └── cli/             # CLI command modules
└── bin/
    └── xm                   # Shell wrapper
```

## Requirements

- **Guile 3.0+** with Goblins 0.17.0
- **Rust toolchain** for building the Oxigraph FFI library
- **Oxigraph 0.4** (via Cargo)

## Commands

### Node Commands
- `xm node create` — Create a new knowledge node
- `xm node get` — Retrieve a node with properties and links
- `xm node update` — Update node properties
- `xm node delete` — Delete a node

### Link Commands
- `xm link create` — Create a link between nodes
- `xm link get` — Retrieve link metadata
- `xm link list` — List links (filterable)
- `xm link delete` — Delete a link

### Query Commands
- `xm query sparql` — Execute SPARQL query
- `xm query nodes` — Search for nodes
- `xm query backlinks` — Find nodes linking TO target
- `xm query path` — Find paths between nodes

### Session Commands
- `xm session start` — Begin a new session
- `xm session end` — End current session
- `xm session list` — List sessions
- `xm session resume` — Resume previous session
- `xm session history` — View session activity

### Capability Commands
- `xm cap create` — Create a capability
- `xm cap attenuate` — Create weaker child capability
- `xm cap revoke` — Revoke a capability
- `xm cap list` — List capabilities
- `xm cap inspect` — Show capability details

### Other Commands
- `xm import` — Import RDF data
- `xm export` — Export to RDF format
- `xm subscribe` — Subscribe to changes
- `xm sync` — Synchronize with remote
- `xm daemon` — Manage the xm daemon

## Output Formats

Human-readable output (default):
```
Node: xm:entity/acme-api
Type: entity

Properties:
  name: acme-api
  kind: repository

Links:
  → xm:uses → xm:entity/fastapi
```

JSON output (`--json`):
```json
{
  "ok": true,
  "data": {
    "node": {
      "id": "xm:entity/acme-api",
      "type": "entity",
      "properties": {"name": "acme-api", "kind": "repository"}
    }
  }
}
```

## Specification

See [SPEC-029-xm-agent-memory-system.md](../SPEC-029-xm-agent-memory-system.md) for the complete specification.

## License

Apache-2.0
