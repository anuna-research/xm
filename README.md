# Meld

Shared memory infrastructure for heterogeneous LLM agents.

## Overview

Meld is a research project exploring how LLM agents (Claude, GPT, Gemini, local models) can share persistent, linked memory. The core component is **xm** (Cross Memory), a CLI tool that any agent can use to store and retrieve knowledge.

## Components

```
meld/
├── xm/                    # Cross Memory CLI tool
├── SPEC-029-*.md          # xm specification
├── SPEC-028-*.md          # Agentic context engineering
└── users/                 # User personas and scenarios
```

### xm (Cross Memory)

A CLI tool providing:

- **Linked Data Memory** — Knowledge as semantic triples (RDF)
- **Capability-Based Access** — Fine-grained permissions via Goblins
- **Bidirectional Links** — Org-roam-inspired backlinks
- **Agent-Agnostic Interface** — JSON-over-stdout for any LLM

See [xm/README.md](xm/README.md) for usage and installation.

## Quick Start

```bash
cd xm
cargo build --release
export PATH="$PWD/bin:$PATH"

# Store a fact
xm node create -t fact -p content="User prefers dark mode"

# Query knowledge
xm query sparql "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10"
```

## License

AGPL-3.0-or-later

Copyright 2026 Hugo O'Connor, Anuna Research
