# SPEC-029: Cross Memory (xm) — Agent Memory System

| Field | Value |
|---|---|
| Document ID | SPEC-029 |
| Title | Cross Memory (xm): Linked Memory for LLM Agents |
| Version | 0.9.0 |
| Status | Draft |
| Created | 2026-01-06 |
| Last Updated | 2026-01-06 |
| Authors | Digital Services Team |
| Reviewers | Technical Lead, Agent Architecture Team |
| Related | [Spritely Goblins 0.17.0](https://files.spritely.institute/docs/guile-goblins/0.17.0/index.html), [Org-roam](https://www.orgroam.com/) |

---

## 1. Executive Summary

**Cross Memory (xm)** is a CLI tool for managing persistent, linked memory across heterogeneous LLM agents. Built on Guile Scheme and Spritely Goblins, it provides:

- **Linked Data Memory**: Knowledge stored as semantic triples following RDF principles
- **Capability-Based Access**: Fine-grained permissions using Goblins' object-capability model
- **Bidirectional Links**: Org-roam-inspired backlinks revealing knowledge relationships
- **Agent-Agnostic Interface**: JSON-over-stdout CLI protocol usable by any LLM agent
- **Distributed by Design**: OCapN-based architecture for secure cross-machine agent collaboration

**Design Philosophy**: Memory as Linked Data

| Principle | Description |
|-----------|-------------|
| Everything is a node | Facts, sessions, agents, and artifacts are first-class graph nodes |
| Links are semantic | Relationships carry meaning (type, provenance, confidence) |
| Capabilities are links | Access rights expressed as capability references |
| Local-first, network-native | Works offline; OCapN enables secure distribution |

---

## 2. Problem Statement

### 2.1 Current Challenges

**For Heterogeneous Agent Ecosystems**:

- LLM agents (Claude, GPT, Gemini, local models) have no shared memory protocol
- Each agent maintains separate, incompatible context formats
- No standard for cross-agent knowledge transfer
- Memory tools are typically language/platform-specific

**For Knowledge Continuity**:

- Agent sessions are ephemeral; knowledge dies with the process
- No mechanism to discover what an agent previously learned
- Related knowledge fragments are not connected
- No backlinks to reveal implicit relationships

**For Security and Trust**:

- Agents often have full access or no access to memory
- No capability-based permissions for sensitive knowledge
- No provenance tracking for facts
- No revocation mechanism for shared knowledge

### 2.2 Requirements

**Functional Requirements**:

| ID | Requirement |
|----|-------------|
| FR-MLD-001 | System SHALL store knowledge as semantic triples (subject-predicate-object) |
| FR-MLD-002 | System SHALL maintain bidirectional links between related nodes |
| FR-MLD-003 | System SHALL provide CLI interface with JSON output for agent consumption |
| FR-MLD-004 | System SHALL support capability-based access control for memory regions |
| FR-MLD-005 | System SHALL track provenance (source, timestamp, confidence) for all facts |
| FR-MLD-006 | System SHALL support sessions with automatic context linking |
| FR-MLD-007 | System SHALL provide backlink queries to discover related knowledge |

**Non-Functional Requirements**:

| ID | Requirement |
|----|-------------|
| NFR-MLD-001 | Single-node queries SHALL complete within 100ms |
| NFR-MLD-002 | Memory store SHALL persist across system restarts |
| NFR-MLD-003 | CLI SHALL work without network connectivity |
| NFR-MLD-004 | Output format SHALL be parseable by any JSON-capable agent |
| NFR-MLD-005 | System SHALL support at least 100,000 nodes per store |

### 2.3 Success Criteria

1. Any LLM agent can read/write memory via CLI without custom integration
2. Knowledge persists across agent sessions and types
3. Backlinks reveal relationships not explicitly queried
4. Capabilities enable fine-grained memory sharing between agents
5. Provenance enables trust assessment of facts

---

## 3. Solution Design

### 3.1 Architecture Overview

xm uses a **three-layer architecture**: OCapN (network), Goblins (security), and Oxigraph (storage).

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Heterogeneous LLM Agents                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │  Claude  │  │   GPT    │  │  Gemini  │  │  Local   │  │  Custom  │       │
│  │  Code    │  │    4     │  │   Pro    │  │  LLaMA   │  │  Agent   │       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│       │             │             │             │             │              │
│       └─────────────┴──────┬──────┴─────────────┴─────────────┘              │
│                            │ CLI or OCapN                                    │
└────────────────────────────┼─────────────────────────────────────────────────┘
                             │
┌────────────────────────────┼─────────────────────────────────────────────────┐
│                    OCapN Network Layer (CapTP)                                │
│                            │                                                  │
│  ┌─────────────────────────┴─────────────────────────────────────────────┐  │
│  │                    Capability Transport Protocol                       │  │
│  │                                                                         │  │
│  │  • Encrypted channels (Tor onion / TCP+TLS / Unix sockets)            │  │
│  │  • Sturdyref resolution across network                                 │  │
│  │  • Promise pipelining for latency reduction                            │  │
│  │  • Third-party handoffs (capability delegation)                        │  │
│  └─────────────────────────┬─────────────────────────────────────────────┘  │
│                            │                                                  │
│  Transports:  [Tor Onion]  [TCP+TLS]  [libp2p]  [Unix Socket]  [WebSocket]  │
└────────────────────────────┼─────────────────────────────────────────────────┘
                             │
┌────────────────────────────┼─────────────────────────────────────────────────┐
│                  Guile Goblins Runtime (Security Layer)                       │
│                            │                                                  │
│  ┌─────────────────────────┴─────────────────────────────────────────────┐  │
│  │                      Graph Gatekeeper Actor                            │  │
│  │                                                                         │  │
│  │  • Validates capabilities (sturdyref → permissions)                    │  │
│  │  • Resolves allowed named graphs per capability                        │  │
│  │  • Rewrites SPARQL queries with FROM <graph> scoping                   │  │
│  │  • Enforces read/write/admin permissions                               │  │
│  │  • All Oxigraph access passes through here                             │  │
│  └─────────────────────────┬─────────────────────────────────────────────┘  │
│                            │                                                  │
│  ┌─────────────┐  ┌────────┴────┐  ┌─────────────┐  ┌─────────────┐         │
│  │Session Actor│  │  Cap Store  │  │ Audit Log   │  │  Netlayer   │         │
│  │ (lifecycle) │  │  (Bloblin)  │  │ (Bloblin)   │  │  (OCapN)    │         │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                                               │
└────────────────────────────┬─────────────────────────────────────────────────┘
                             │ scoped SPARQL queries only
                             ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                       Oxigraph (Storage Layer via FFI)                        │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                          Quad Store (RocksDB)                           │ │
│  │                                                                          │ │
│  │   • No access control - trusts scoped queries from Goblins              │ │
│  │   • SPARQL 1.1 Query/Update engine                                      │ │
│  │   • RDF serialization (Turtle, N-Triples, JSON-LD)                      │ │
│  │   • Indexed retrieval via RocksDB                                       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Network-First Design**:

LLM agents are inherently distributed—Claude runs on Anthropic's infrastructure, GPT on OpenAI's, local models on user machines. OCapN enables secure capability sharing across these boundaries:

```
┌─────────────────┐                              ┌─────────────────┐
│  Claude Code    │                              │   GPT Agent     │
│  (Anthropic)    │                              │   (OpenAI)      │
│                 │      CapTP (encrypted)       │                 │
│  cap:abc123... ─┼──────────────────────────────┼─► cap:abc123... │
│                 │      sturdyref delegation    │   (attenuated)  │
└─────────────────┘                              └─────────────────┘
        │                                                │
        │ OCapN                                          │ OCapN
        ▼                                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      xm Daemon (User's Machine)                │
│                                                                  │
│   Goblins validates both capabilities against same store        │
│   Each agent sees only their authorized named graphs            │
└─────────────────────────────────────────────────────────────────┘
```

**Security Flow**:

1. Remote agent connects via OCapN (CapTP over Tor/TLS)
2. Agent presents capability sturdyref
3. Goblins validates capability, resolves allowed named graphs
4. Query rewritten to scope to allowed graphs only
5. Scoped query executed against Oxigraph via FFI
6. Results returned through encrypted OCapN channel

### 3.2 Technology Choices

**Three-Layer Stack**:

| Layer | Technology | Purpose |
|-------|------------|---------|
| Network | OCapN (CapTP) | Secure capability transport across machines |
| Security | Guile Scheme 3.0+ / Spritely Goblins 0.17.0 | Capabilities, sessions, access control |
| Storage | Oxigraph (Rust/RocksDB) via FFI | SPARQL queries, RDF storage, indexing |

**Rationale for OCapN (Network Layer)**:

| Feature | Benefit for xm |
|---------|------------------|
| CapTP protocol | Capabilities work identically local or remote |
| Sturdyrefs | Persistent capability references across restarts/networks |
| Promise pipelining | Reduces round-trips for chained operations |
| Third-party handoffs | Agent A can delegate capability to Agent B |
| Multiple transports | Tor (anonymity), TLS (speed), Unix (local) |
| E-order delivery | Messages arrive in causal order |

**Rationale for Goblins (Security Layer)**:

| Feature | Benefit for xm |
|---------|------------------|
| Object capabilities | Fine-grained access control without ACLs |
| Sturdyrefs | Persistent capability tokens survive restarts |
| Transactional safety | Capability checks are atomic |
| Bloblin persistence | Secure storage for capability metadata |
| OCapN networking | Secure distributed agent collaboration |

**Rationale for Oxigraph (Storage Layer)**:

| Feature | Benefit for xm |
|---------|------------------|
| SPARQL 1.1 | Full query/update language - no custom implementation |
| Named graphs (quads) | Natural security boundary per capability |
| RocksDB backend | Fast indexed retrieval at scale |
| RDF serialization | Native Turtle, N-Triples, JSON-LD import/export |
| Rust + C ABI | Safe FFI from Guile |

**FFI Binding Approach**:

```
Guile ──(FFI)──► C ABI ──► Rust (oxigraph crate)
                  │
            cbindgen-generated
            header from Rust
```

**Storage Split**:

| Data | Stored In | Reason |
|------|-----------|--------|
| RDF triples (knowledge) | Oxigraph | Fast SPARQL, RDF-native indexing |
| Capability definitions | Bloblin | Goblins sturdyrefs, tamper-evident |
| Capability→Graph mappings | Bloblin | Security-critical, capability-protected |
| Session state | Bloblin | Actor state persistence |
| Audit log | Bloblin | Append-only, survives restarts |

**Storage Locations**:

```
~/.local/share/xm/
├── oxigraph/              # Oxigraph RocksDB store
│   └── (RocksDB files)    # Quad storage, indexes
├── goblins/               # Goblins Bloblin store
│   ├── capabilities.bloblin   # Capability definitions
│   ├── sessions.bloblin       # Session state
│   └── audit.bloblin          # Audit log (append-only)
└── config.scm             # User configuration
```

### 3.3 Vocabulary

xm reuses established semantic web vocabularies wherever possible, defining custom terms only where no suitable standard exists.

#### 3.3.1 Namespace Prefixes

| Prefix | Namespace URI | Specification |
|--------|---------------|---------------|
| `rdf:` | http://www.w3.org/1999/02/22-rdf-syntax-ns# | [RDF 1.1](https://www.w3.org/TR/rdf11-concepts/) |
| `rdfs:` | http://www.w3.org/2000/01/rdf-schema# | [RDF Schema](https://www.w3.org/TR/rdf-schema/) |
| `xsd:` | http://www.w3.org/2001/XMLSchema# | [XML Schema](https://www.w3.org/TR/xmlschema-2/) |
| `prov:` | http://www.w3.org/ns/prov# | [PROV-O](https://www.w3.org/TR/prov-o/) |
| `dcterms:` | http://purl.org/dc/terms/ | [Dublin Core Terms](https://www.dublincore.org/specifications/dublin-core/dcmi-terms/) |
| `skos:` | http://www.w3.org/2004/02/skos/core# | [SKOS](https://www.w3.org/TR/skos-reference/) |
| `xm:` | https://xm.dev/ns/v1# | xm-specific (this spec) |

#### 3.3.2 Standard Vocabulary Mapping

**Classes** (node types):

| xm Type | Standard Class | Notes |
|-----------|----------------|-------|
| Entity/Fact | `prov:Entity` | All knowledge nodes are PROV entities |
| Session | `prov:Activity` | Sessions are activities that generate entities |
| Agent | `prov:SoftwareAgent` | LLM agents are software agents |

**Properties** (predicates):

| Relationship | Standard Property | URI |
|--------------|-------------------|-----|
| created-at | `dcterms:created` | http://purl.org/dc/terms/created |
| modified-at | `dcterms:modified` | http://purl.org/dc/terms/modified |
| authored-by | `prov:wasAttributedTo` | http://www.w3.org/ns/prov#wasAttributedTo |
| generated-by (session) | `prov:wasGeneratedBy` | http://www.w3.org/ns/prov#wasGeneratedBy |
| primary-source | `prov:hadPrimarySource` | http://www.w3.org/ns/prov#hadPrimarySource |
| supersedes | `dcterms:replaces` | http://purl.org/dc/terms/replaces |
| related-to | `skos:related` | http://www.w3.org/2004/02/skos/core#related |
| label | `rdfs:label` | http://www.w3.org/2000/01/rdf-schema#label |
| description | `rdfs:comment` | http://www.w3.org/2000/01/rdf-schema#comment |

#### 3.3.3 xm-Specific Vocabulary

The following terms have no suitable standard equivalent and are defined in the `xm:` namespace:

| Term | Type | URI | Description |
|------|------|-----|-------------|
| `xm:confidence` | Property | https://xm.dev/ns/v1#confidence | Numeric confidence score (0.0-1.0) for a fact |
| `xm:dependsOn` | Property | https://xm.dev/ns/v1#dependsOn | Software/system dependency relationship |
| `xm:uses` | Property | https://xm.dev/ns/v1#uses | Technology/framework usage relationship |
| `xm:Capability` | Class | https://xm.dev/ns/v1#Capability | Object-capability access token |
| `xm:capabilityScope` | Property | https://xm.dev/ns/v1#capabilityScope | Scope of a capability (node, subgraph, global) |
| `xm:capabilityExpires` | Property | https://xm.dev/ns/v1#capabilityExpires | Expiration timestamp for a capability |

#### 3.3.4 Vocabulary Usage in CLI

The CLI accepts both full URIs and shorthand prefixes:

```bash
# Full URI
xm link create --predicate "http://purl.org/dc/terms/replaces" ...

# Prefixed (preferred)
xm link create --predicate "dcterms:replaces" ...

# xm shorthand (for xm: namespace)
xm link create --predicate "uses" ...  # expands to xm:uses
```

### 3.4 Semantic Data Model

#### 3.4.1 Node Types

All knowledge is represented as **nodes** in a semantic graph.

```scheme
;; Core node structure
(define-actor-type <xm-node>
  (fields
    id           ; URI: xm:node/{uuid}
    type         ; Symbol: 'fact | 'entity | 'session | 'agent | 'artifact
    created-at   ; ISO 8601 timestamp
    updated-at   ; ISO 8601 timestamp
    properties   ; Association list of key-value pairs
    provenance)) ; Source, confidence, method

;; Node types and their purposes
```

| Type | Purpose | Example |
|------|---------|---------|
| `fact` | Atomic knowledge claim | "acme-api uses FastAPI" |
| `entity` | Named thing in the domain | "acme-api" (the repo itself) |
| `session` | Agent interaction context | "Debugging auth bug session" |
| `agent` | LLM agent identity | "claude-code-2026-01-06" |
| `artifact` | Generated/referenced file | "src/auth.py analysis" |

#### 3.4.2 Link Types (Semantic Predicates)

Links connect nodes with typed, directional relationships.

```scheme
;; Core link structure
(define-actor-type <xm-link>
  (fields
    id           ; URI: xm:link/{uuid}
    source       ; Node URI (subject)
    predicate    ; Standard or xm: URI
    target       ; Node URI or literal (object)
    created-at
    provenance
    properties)) ; Optional metadata
```

**Predicates** (standard vocabularies used where possible):

| Predicate | URI | Domain → Range | Example |
|-----------|-----|----------------|---------|
| `xm:uses` | xm:uses | entity → entity | acme-api uses FastAPI |
| `xm:dependsOn` | xm:dependsOn | entity → entity | web-frontend dependsOn auth-service |
| `prov:wasGeneratedBy` | prov:wasGeneratedBy | entity → activity | Fact generated by Session |
| `prov:wasAttributedTo` | prov:wasAttributedTo | entity → agent | Analysis attributed to Claude |
| `skos:related` | skos:related | any → any | Generic relationship |
| `dcterms:replaces` | dcterms:replaces | entity → entity | Newer fact replaces older |
| `xm:confidence` | xm:confidence | entity → xsd:decimal | Confidence score (0.0-1.0) |
| `prov:hadPrimarySource` | prov:hadPrimarySource | entity → entity | Origin URL or identifier |

#### 3.4.3 Named Graphs (Security Boundaries)

All RDF data is stored as **quads** (subject, predicate, object, **graph**). Named graphs serve as security boundaries for capability scoping.

**Graph Hierarchy**:

| Graph Pattern | Access Level | Example |
|---------------|--------------|---------|
| `xm:graph/public` | No capability required | Public ontology, shared vocabulary |
| `xm:graph/agent/{id}` | Agent's own data | `xm:graph/agent/claude-code` |
| `xm:graph/project/{id}` | Project team members | `xm:graph/project/acme-api` |
| `xm:graph/session/{id}` | Session owner only | `xm:graph/session/abc123` |

**Example Data Distribution**:

```turtle
# Public knowledge (no capability needed)
GRAPH <xm:graph/public> {
  <xm:entity/fastapi> a xm:Framework ;
    rdfs:label "FastAPI" ;
    rdfs:comment "Modern Python web framework" .
}

# Project-scoped (capability required)
GRAPH <xm:graph/project/acme-api> {
  <xm:entity/acme-api> a xm:Repository ;
    rdfs:label "acme-api" ;
    xm:uses <xm:entity/fastapi> ;
    xm:dependsOn <xm:entity/auth-service> .
}

# Session-private (only session owner)
GRAPH <xm:graph/session/abc123> {
  <xm:fact/xyz789> a prov:Entity ;
    rdfs:label "OAuth callback is /auth/callback" ;
    prov:wasGeneratedBy <xm:session/abc123> ;
    xm:confidence 0.95 .
}
```

**Query Scoping**:

When an agent queries with a capability, the query is automatically scoped:

```sparql
# Agent's query:
SELECT ?dep WHERE { ?project xm:dependsOn ?dep }

# Rewritten with capability scope (agent can access public + acme-api):
SELECT ?dep
FROM <xm:graph/public>
FROM <xm:graph/project/acme-api>
WHERE { ?project xm:dependsOn ?dep }
```

Data in `xm:graph/project/secret-project` is invisible to this query.

#### 3.4.4 Backlinks (Org-roam Inspiration)

Every link automatically creates a queryable backlink.

```
Forward:  (acme-api) --[uses]--> (FastAPI)
Backlink: (FastAPI) <--[used-by]-- (acme-api)
```

**Backlink Query Example**:

```bash
# "What uses FastAPI?"
xm query backlinks --node "xm:entity/fastapi" --predicate "xm:uses"

# Output shows all nodes that link TO FastAPI with "xm:uses" predicate
```

### 3.5 Capability Model

#### 3.5.1 Capability Structure

Capabilities grant access to **named graphs**, not individual nodes. This integrates with Oxigraph's quad model.

```scheme
;; Capability structure (stored in Bloblin)
(define-record-type <xm-capability>
  (make-xm-capability id graphs permissions expires created-by)
  xm-capability?
  (id cap-id)                    ; Sturdyref token (xm:cap/{token})
  (graphs cap-graphs)            ; List of allowed named graphs
  (permissions cap-permissions)  ; '(read) | '(read write) | '(read write admin)
  (expires cap-expires)          ; #f or ISO 8601 timestamp
  (created-by cap-created-by))   ; Parent capability (for attenuation audit)
```

| Permission | Allows | SPARQL Operations |
|------------|--------|-------------------|
| `read` | Query allowed graphs | SELECT, ASK, CONSTRUCT, DESCRIBE |
| `write` | Insert/update in allowed graphs | INSERT DATA, DELETE DATA |
| `admin` | Delete graphs, modify capabilities | DROP GRAPH, capability attenuation |

#### 3.5.2 Capability Attenuation

Capabilities can only be **attenuated** (weakened), never strengthened. A child capability must be a subset of its parent:

```scheme
;; Valid attenuation: fewer graphs, fewer permissions, shorter expiry
(attenuate parent-cap
  #:graphs '("xm:graph/public")  ; subset of parent's graphs
  #:permissions '(read)             ; subset of parent's permissions
  #:expires "2026-02-01")           ; earlier than parent's expiry

;; Invalid: would grant access parent doesn't have
(attenuate parent-cap
  #:graphs '("xm:graph/secret"))  ; ERROR: not in parent's graphs
```

#### 3.5.3 Capability Sharing Protocol

```bash
# Create a capability granting access to specific graphs
xm cap create --graphs "xm:graph/public,xm:graph/project/acme-api" \
                --permissions read,write \
                --expires "2026-02-01"

# Output: capability sturdyref (shareable token)
{
  "cap_ref": "xm:cap/abc123...",
  "graphs": ["xm:graph/public", "xm:graph/project/acme-api"],
  "permissions": ["read", "write"],
  "expires": "2026-02-01T00:00:00Z"
}

# Attenuate to create a read-only capability for sharing
xm cap attenuate --cap "xm:cap/abc123..." \
                   --graphs "xm:graph/public" \
                   --permissions read

# Another agent uses the capability (queries auto-scoped)
xm query sparql --cap "xm:cap/abc123..." \
  "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10"
```

#### 3.5.4 Public Graph (No Capability Required)

The `xm:graph/public` graph is readable without a capability:

```bash
# Public queries don't require --cap
xm query sparql "SELECT ?s WHERE { ?s a xm:Framework }"
# Automatically scoped to: FROM <xm:graph/public>
```

### 3.6 Session Model

Sessions group related interactions and automatically link discoveries.

```scheme
(define-actor-type <xm-session>
  (fields
    id           ; xm:session/{uuid}
    agent-id     ; Which agent started this
    purpose      ; Human-readable description
    started-at
    ended-at     ; nil if active
    context      ; Links to relevant nodes at start
    discoveries  ; Nodes/links created during session
    parent))     ; Optional parent session for continuations
```

**Session Lifecycle**:

```bash
# Start a session (returns session ID)
xm session start --agent "claude-code" --purpose "Debug auth flow"

# Session context: what nodes should be loaded
xm session context --add "xm:entity/acme-api"
xm session context --add "xm:entity/auth-service"

# During work, facts are auto-linked to session
xm node create --type fact \
                 --property "content=OAuth callback URL is /auth/callback" \
                 --property "subject=xm:entity/acme-api"
# Automatically: fact --[prov:wasGeneratedBy]--> current-session

# End session (snapshots discoveries)
xm session end --summary "Found OAuth misconfiguration"

# Resume later
xm session resume --id "xm:session/abc123"
```

### 3.7 State Synchronization

xm leverages Goblins' native distributed primitives for state synchronization between heterogeneous agents.

#### 3.7.1 Synchronization Patterns

| Pattern | Mechanism | Use Case |
|---------|-----------|----------|
| Pull-based | Query via sturdyref | Agent queries when needed |
| Push-based | Pubsub subscriptions | Real-time change notifications |
| Handoff | Capability delegation | Transfer session to another agent |

#### 3.7.2 Sturdyref Sharing (Remote Capability Access)

Agents access remote xm daemons by enlivening sturdyrefs shared out-of-band:

```scheme
;;; Server side: register gatekeeper, get shareable sturdyref
(define mycapn (spawn ^mycapn #:netlayers (list tor-netlayer)))
(define gatekeeper-ref
  (<- mycapn 'register graph-gatekeeper "tor"))
(define shareable-uri (ocapn-id->string gatekeeper-ref))
;; => "ocapn:tor:xyz123...#swiss-num"

;;; Client side: enliven sturdyref to get live remote reference
(define remote-gatekeeper
  (<- mycapn 'enliven (string->ocapn-id shareable-uri)))

;; Now invoke as if local (CapTP handles network transparently)
(<- remote-gatekeeper 'query cap-ref "SELECT ?s ?p ?o WHERE {...}")
```

**CLI equivalent**:
```bash
# Connect to remote xm daemon
xm --remote "ocapn:tor:xyz123...#swiss-num" query sparql "SELECT ..."
```

#### 3.7.3 Pubsub for Change Notifications

The Graph Gatekeeper maintains a pubsub actor for broadcasting graph mutations:

```scheme
;;; xm/sync.scm - Change notification via Goblins pubsub

(use-modules (goblins actor-lib pubsub))

;;; Graph Change Notifier - wraps gatekeeper with pubsub
(define (^graph-change-notifier bcom gatekeeper)
  (define change-pubsub (spawn ^pubsub))

  (methods
   ;; Subscribe to changes (returns subscription handle)
   [(subscribe callback)
    (<- change-pubsub 'subscribe callback)]

   ;; Unsubscribe
   [(unsubscribe callback)
    (<- change-pubsub 'unsubscribe callback)]

   ;; Insert with notification
   [(insert cap-ref graph-uri triples-turtle)
    (let ((result (<- gatekeeper 'insert cap-ref graph-uri triples-turtle)))
      ;; Notify all subscribers
      (<- change-pubsub 'publish
          'insert graph-uri triples-turtle (current-time))
      result)]

   ;; Delete with notification
   [(delete cap-ref graph-uri pattern)
    (let ((result (<- gatekeeper 'delete cap-ref graph-uri pattern)))
      (<- change-pubsub 'publish
          'delete graph-uri pattern (current-time))
      result)]

   ;; Query (no notification, just passthrough)
   [(query cap-ref sparql-string)
    (<- gatekeeper 'query cap-ref sparql-string)]))
```

**Subscription flow**:

```
┌─────────────────┐                              ┌─────────────────┐
│  Claude Code    │                              │   GPT Agent     │
│  (Anthropic)    │                              │   (OpenAI)      │
│                 │      subscribe via OCapN     │                 │
│  on-change ─────┼──────────────────────────────┼──► on-change    │
│  callback       │                              │     callback    │
└────────┬────────┘                              └────────┬────────┘
         │                                                │
         │                                                │
         ▼                                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ^graph-change-notifier                        │
│                                                                  │
│   subscribers: [claude-callback, gpt-callback, ...]             │
│                                                                  │
│   On INSERT → publish ('insert graph triples timestamp)         │
│   On DELETE → publish ('delete graph pattern timestamp)         │
└─────────────────────────────────────────────────────────────────┘
```

**CLI subscription** (streaming NDJSON):

```bash
# Subscribe to changes on graphs accessible via capability
xm subscribe --cap "xm:cap/abc123" --graphs "xm:graph/project/acme-api"

# Output (streaming, one JSON object per line):
{"event":"insert","graph":"xm:graph/project/acme-api","data":{...},"timestamp":"2026-01-06T12:00:00Z"}
{"event":"delete","graph":"xm:graph/project/acme-api","data":{...},"timestamp":"2026-01-06T12:01:00Z"}
```

#### 3.7.4 Promise Pipelining for Efficient Queries

Goblins' promise pipelining reduces round-trips for chained operations:

```scheme
;; Without pipelining: 4 round trips
;; 1. Get session → 2. Get context → 3. Query graph → 4. Return results

;; With pipelining: 2 round trips
;; Bundle: "Get session, get its context, query those nodes"
(define results
  (<- (<- (<- session-actor 'get-context)
          'map (lambda (node) (<- gatekeeper 'query cap node-query)))
      'collect))
```

This is particularly important for geographically distributed agents where latency dominates.

#### 3.7.5 Reconnection and Partition Handling

**Sturdyref resilience**: Sturdyrefs remain valid across disconnections. When connection is restored, the reference automatically reconnects to the same actor.

**Handling partitions**:

```scheme
;; Promises to disconnected peers become "broken"
(on (<- remote-gatekeeper 'query cap sparql)
    (lambda (result)
      (process-result result))
    #:catch (lambda (err)
      (cond
        [(disconnection-error? err)
         ;; Queue for retry, use cached data
         (queue-for-retry cap sparql)
         (use-cached-result cap sparql)]
        [else (raise err)])))
```

**Offline operation**: Agents can operate against local store, queueing mutations for sync when reconnected:

```bash
# Offline: writes go to local queue
xm --offline node create --type fact --property "content=..."

# On reconnect: sync queued changes
xm sync --target "ocapn:tor:xyz..."
```

#### 3.7.6 Conflict Resolution

For concurrent writes to the same graph by multiple agents, xm uses **last-write-wins** with full provenance:

```turtle
# Both agents write to same entity
# Agent A at T1:
<xm:entity/acme-api> xm:uses <xm:entity/fastapi-0.99> .

# Agent B at T2 (T2 > T1):
<xm:entity/acme-api> xm:uses <xm:entity/fastapi-0.100> .

# Result: Agent B's write wins, but A's write preserved in history
GRAPH <xm:graph/project/acme-api> {
  <xm:entity/acme-api> xm:uses <xm:entity/fastapi-0.100> .
}

GRAPH <xm:graph/history/acme-api> {
  _:change1 a xm:SupersededFact ;
    prov:value <xm:entity/fastapi-0.99> ;
    prov:wasAttributedTo <xm:agent/claude-code> ;
    dcterms:created "2026-01-06T12:00:00Z" ;
    dcterms:replaces _:change0 .
}
```

**Future consideration**: CRDTs for specific data types (counters, sets) where automatic merge is preferable to last-write-wins.

### 3.8 Store-and-Forward Messaging

Real-time pubsub (Section 3.7.3) loses messages when subscribers are offline. Store-and-forward ensures reliable delivery using Goblins' persistent queue primitives.

#### 3.8.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           xm Daemon                                        │
│                                                                              │
│  ┌──────────────┐    ┌──────────────────┐    ┌────────────────────────────┐│
│  │ Graph        │    │  Event Journal   │    │  Subscription Registry     ││
│  │ Gatekeeper   │───►│  (append-only)   │◄───│                            ││
│  │              │    │                  │    │  subscriber-a: cursor=1005 ││
│  │  on mutate:  │    │  seq=1001: {...} │    │  subscriber-b: cursor=1003 ││
│  │  append to   │    │  seq=1002: {...} │    │  subscriber-c: cursor=1005 ││
│  │  journal     │    │  seq=1003: {...} │    │                            ││
│  └──────────────┘    │  seq=1004: {...} │    └────────────────────────────┘│
│                      │  seq=1005: {...} │                                   │
│                      └────────┬─────────┘                                   │
│                               │                                              │
│                               │ replay from cursor                          │
│                               ▼                                              │
└───────────────────────────────┼─────────────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ Agent A       │      │ Agent B       │      │ Agent C       │
│ (online)      │      │ (reconnected) │      │ (offline)     │
│               │      │               │      │               │
│ cursor: 1005  │      │ cursor: 1003  │      │ cursor: 998   │
│ real-time ✓   │      │ replaying     │      │ queued locally│
│               │      │ 1003→1005     │      │               │
└───────────────┘      └───────────────┘      └───────────────┘
```

#### 3.8.2 Event Journal

The Event Journal is an append-only log of all graph mutations, stored in Bloblin for durability.

```scheme
;;; xm/journal.scm - Persistent event journal

(use-modules (goblins)
             (goblins actor-lib queue)
             (goblins persist))

;;; Event structure
(define-record-type <journal-event>
  (make-journal-event seq timestamp event-type graph-uri data agent-id)
  journal-event?
  (seq journal-event-seq)              ; Monotonic sequence number
  (timestamp journal-event-timestamp)  ; ISO 8601
  (event-type journal-event-type)      ; 'insert | 'delete | 'clear
  (graph-uri journal-event-graph)      ; Affected graph
  (data journal-event-data)            ; Triples or pattern
  (agent-id journal-event-agent))      ; Who made the change

;;; Event Journal Actor
(define (^event-journal bcom)
  (define next-seq 1)
  (define events (spawn ^queue))  ; Persistent via queue-env

  (methods
   ;; Append new event, return sequence number
   [(append event-type graph-uri data agent-id)
    (let* ((seq next-seq)
           (event (make-journal-event
                   seq (current-iso-timestamp)
                   event-type graph-uri data agent-id)))
      (set! next-seq (+ seq 1))
      (<- events 'enqueue event)
      seq)]

   ;; Read events from sequence number (inclusive)
   [(read-from start-seq #:optional (limit 1000))
    (filter (lambda (e) (>= (journal-event-seq e) start-seq))
            (take (<- events 'to-list) limit))]

   ;; Get current head sequence
   [(head-seq)
    (- next-seq 1)]

   ;; Compact old events (admin operation)
   [(compact before-seq)
    ;; Move old events to cold storage, keep recent in hot journal
    ...]))
```

**Journal persistence**:

```
~/.local/share/xm/
├── goblins/
│   ├── journal.bloblin      # Event journal (hot)
│   ├── journal-archive/     # Compacted events (cold)
│   └── subscriptions.bloblin # Subscriber cursors
```

#### 3.8.3 Subscription Cursors

Each subscriber maintains a **cursor** (last-seen sequence number). On reconnect, events from cursor to head are replayed.

```scheme
;;; xm/subscriptions.scm - Subscription management with cursors

(define (^subscription-registry bcom journal)
  (define cursors (make-hash-table))  ; subscriber-id → seq

  (methods
   ;; Register new subscriber, optionally from specific sequence
   [(subscribe subscriber-id callback #:optional (from-seq #f))
    (let ((start-seq (or from-seq (<- journal 'head-seq))))
      (hash-set! cursors subscriber-id start-seq)
      ;; Return current position
      start-seq)]

   ;; Update cursor after successful delivery
   [(ack subscriber-id seq)
    (let ((current (hash-ref cursors subscriber-id 0)))
      (when (> seq current)
        (hash-set! cursors subscriber-id seq)))]

   ;; Get events subscriber hasn't seen
   [(pending-for subscriber-id)
    (let ((cursor (hash-ref cursors subscriber-id 0)))
      (<- journal 'read-from (+ cursor 1)))]

   ;; Unsubscribe
   [(unsubscribe subscriber-id)
    (hash-remove! cursors subscriber-id)]))
```

#### 3.8.4 Outbox for Offline Mutations

When an agent operates offline, mutations queue in a local **outbox** and replay on reconnect.

```scheme
;;; xm/outbox.scm - Local mutation queue for offline operation

(define (^outbox bcom)
  (define queue (spawn ^queue))  ; Persistent
  (define pending-count 0)

  (methods
   ;; Queue mutation for later sync
   [(enqueue mutation)
    (set! pending-count (+ pending-count 1))
    (<- queue 'enqueue
        (cons (current-iso-timestamp) mutation))]

   ;; Drain outbox, applying mutations to remote
   [(flush remote-gatekeeper cap-ref)
    (let loop ((results '()))
      (if (<- queue 'empty?)
          (begin
            (set! pending-count 0)
            (reverse results))
          (let* ((item (<- queue 'dequeue))
                 (timestamp (car item))
                 (mutation (cdr item))
                 (result (apply-mutation remote-gatekeeper cap-ref mutation)))
            (loop (cons result results)))))]

   ;; Check pending count
   [(pending) pending-count]))

(define (apply-mutation gatekeeper cap-ref mutation)
  (match mutation
    [('insert graph-uri triples)
     (<- gatekeeper 'insert cap-ref graph-uri triples)]
    [('delete graph-uri pattern)
     (<- gatekeeper 'delete cap-ref graph-uri pattern)]))
```

**Offline workflow**:

```
┌─────────────────┐                         ┌─────────────────┐
│  Agent (local)  │                         │  xm Daemon      │
│                 │                         │  (unreachable)  │
│  xm --offline │         ✗ network       │                 │
│  node create    │─────────────────────────│                 │
│       │         │                         │                 │
│       ▼         │                         │                 │
│  ┌─────────┐    │                         │                 │
│  │ Outbox  │    │                         │                 │
│  │ queue   │    │     (later, online)     │                 │
│  │ ┌─────┐ │    │                         │                 │
│  │ │mut 1│ │    │     xm sync           │                 │
│  │ │mut 2│ │────┼────────────────────────►│  Apply mut 1    │
│  │ │mut 3│ │    │     flush outbox        │  Apply mut 2    │
│  │ └─────┘ │    │                         │  Apply mut 3    │
│  └─────────┘    │                         │                 │
└─────────────────┘                         └─────────────────┘
```

#### 3.8.5 Reliable Delivery Protocol

Combining journal, cursors, and outbox for guaranteed delivery:

```scheme
;;; xm/reliable-sync.scm - Reliable bidirectional sync

(define (^reliable-sync bcom local-gatekeeper remote-ref outbox journal subscriptions)

  (methods
   ;; Full sync: push local changes, pull remote changes
   [(sync cap-ref)
    (let ((push-results (push-outbox cap-ref))
          (pull-results (pull-pending cap-ref)))
      `((pushed . ,push-results)
        (pulled . ,pull-results)))]

   ;; Push queued local mutations to remote
   [(push-outbox cap-ref)
    (<- outbox 'flush remote-ref cap-ref)]

   ;; Pull missed events from remote
   [(pull-pending cap-ref)
    (let* ((my-id (get-subscriber-id))
           (events (<- remote-ref 'pending-for my-id)))
      (for-each
       (lambda (event)
         ;; Apply to local store
         (apply-event-locally local-gatekeeper event)
         ;; Acknowledge receipt
         (<- remote-ref 'ack my-id (journal-event-seq event)))
       events)
      (length events))]))
```

#### 3.8.6 Delivery Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| **At-least-once delivery** | Events replayed until acknowledged |
| **Ordering** | Sequence numbers ensure causal order |
| **Durability** | Bloblin persistence survives crashes |
| **Distributed consistency** | Last-write-wins with provenance (Section 3.7.6) |

**Not guaranteed** (by design):
- Exactly-once delivery (idempotent mutations recommended)
- Global ordering across multiple servers (local ordering only)

#### 3.8.7 Journal Compaction

Old events are compacted to manage storage growth:

```bash
# Compact events older than 30 days
xm admin journal compact --before "30d"

# Output
{
  "ok": true,
  "data": {
    "compacted_events": 15234,
    "archived_to": "~/.local/share/xm/goblins/journal-archive/2025-12.bloblin",
    "current_head": 45678,
    "oldest_available": 30444
  }
}
```

Subscribers with cursors older than the oldest available event receive a `cursor-expired` error and must re-sync from a snapshot.

---

## 4. CLI Specification

### 4.1 Design Principles

Following [Command Line Interface Guidelines](https://clig.dev/):

1. **Human-Readable by Default**: Output is formatted for humans; use `--json` for machine parsing
2. **Stdout for Data, Stderr for Messages**: Primary output goes to stdout; progress, warnings, and errors go to stderr
3. **Composable**: Commands can be piped; support `-` for stdin/stdout
4. **Idempotent Where Possible**: Same input produces same result; operations recoverable from interruption
5. **Explicit Over Magic**: No hidden side effects; confirm dangerous operations
6. **Flags Over Positional Arguments**: Prefer `--source X` over positional args for clarity
7. **Consistent Across Subcommands**: Same flag names, output formatting, and terminology throughout
8. **Fail Fast with Actionable Errors**: Validate input early; provide guidance on how to fix problems

### 4.2 Global Options

```bash
xm [global-options] <command> [command-options]

Global Options:
  -h, --help           Show help for command (with examples)
  --version            Show version and exit

  -d, --debug          Include debug information in output
  -q, --quiet          Suppress non-essential output (warnings, progress)
  -v, --verbose        Show detailed operation progress

  --json               Output in JSON format (default: human-readable)
  --no-color           Disable colored output (also honors NO_COLOR env var)
  --no-input           Disable all interactive prompts (for scripting)

  --store PATH         Path to xm store (default: $XM_STORE or ~/.local/share/xm)
  --session ID         Use existing session (else: ephemeral)
  --cap REF            Capability reference for access control
  --remote URI         Connect to remote xm daemon via OCapN
```

### 4.3 Environment Variables

Environment variables use `XM_` prefix. Configuration precedence (highest to lowest):

1. Command-line flags
2. Environment variables
3. Project-level config (`.xm.toml` in current directory)
4. User-level config (`~/.config/xm/config.toml`)
5. System-wide config (`/etc/xm/config.toml`)

```bash
# xm-specific variables
XM_STORE           # Path to xm store (default: ~/.local/share/xm)
XM_CAP             # Default capability reference
XM_SESSION         # Default session ID
XM_REMOTE          # Default remote server URI
XM_DEBUG           # Enable debug mode (1 = on)

# Standard variables honored
NO_COLOR             # Disable colored output (any value)
EDITOR               # Editor for interactive editing
PAGER                # Pager for long output (default: less)
HOME                 # User home directory
XDG_CONFIG_HOME      # Config directory (default: ~/.config)
XDG_DATA_HOME        # Data directory (default: ~/.local/share)
```

**Never read secrets from environment variables**. Capability references should be passed via `--cap` flag, read from config files with appropriate permissions, or piped via stdin.

### 4.4 Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (invalid input, operation failed) |
| 2 | Usage error (invalid flags, missing required arguments) |
| 3 | Permission denied (capability lacks required access) |
| 4 | Not found (node, session, or capability doesn't exist) |
| 5 | Conflict (concurrent modification, constraint violation) |
| 130 | Interrupted (Ctrl-C) |

### 4.5 Output Formats

**Human-readable (default)**:
```bash
$ xm node get xm:entity/acme-api

Node: xm:entity/acme-api
Type: entity
Created: 2026-01-06 09:00:00

Properties:
  name: acme-api
  kind: repository

Links:
  → xm:uses → xm:entity/fastapi
  → xm:dependsOn → xm:entity/auth-service

Backlinks:
  ← skos:related ← xm:entity/SPEC-022
```

**JSON (--json flag)**:
```bash
$ xm node get xm:entity/acme-api --json

{
  "ok": true,
  "data": {
    "node": {
      "id": "xm:entity/acme-api",
      "type": "entity",
      "properties": {"name": "acme-api", "kind": "repository"},
      "created_at": "2026-01-06T09:00:00Z"
    },
    "links": [...],
    "backlinks": [...]
  },
  "meta": {
    "timestamp": "2026-01-06T10:30:00Z",
    "request_id": "req-xyz789"
  }
}
```

**NDJSON (streaming results)**:
```bash
$ xm query nodes --type entity --json

{"id": "xm:entity/acme-api", "type": "entity", ...}
{"id": "xm:entity/web-frontend", "type": "entity", ...}
```

### 4.6 Error Handling

Errors are written to stderr with actionable guidance:

```bash
$ xm node get xm:entity/nonexistent

Error: Node not found
  Node ID: xm:entity/nonexistent

  Did you mean one of these?
    xm:entity/acme-api
    xm:entity/auth-service

  To search for nodes: xm query nodes --type entity
```

```bash
$ xm node create --type fact --cap xm:cap/readonly

Error: Permission denied
  Operation: write
  Capability: xm:cap/readonly
  Granted: [read]
  Required: [write]

  To create a write capability: xm cap create --permissions read,write
```

**JSON error format** (`--json` flag):
```json
{
  "ok": false,
  "error": {
    "code": "NODE_NOT_FOUND",
    "message": "Node not found",
    "details": {
      "node_id": "xm:entity/nonexistent",
      "suggestions": ["xm:entity/acme-api", "xm:entity/auth-service"]
    }
  },
  "meta": {...}
}
```

### 4.7 Help Text

Help text leads with examples, then formal documentation:

```bash
$ xm node create --help

Create a new knowledge node in the graph.

Examples:
  # Create an entity
  xm node create --type entity --property name=acme-api --property kind=repository

  # Create a fact with links
  xm node create --type fact \
    --property "content=Uses FastAPI 0.100+" \
    --link skos:related:xm:entity/acme-api

  # Read properties from stdin
  echo '{"name": "api", "kind": "service"}' | xm node create --type entity --properties -

Usage:
  xm node create --type TYPE [flags]

Flags:
  -t, --type TYPE              Node type: entity, fact, session, agent, artifact (required)
  -p, --property KEY=VALUE     Set property (can be repeated)
  -l, --link PRED:TARGET       Create link to target (can be repeated)
  -g, --graph URI              Target graph (default: session graph or public)
      --properties FILE        Read properties from JSON file (use - for stdin)
  -n, --dry-run                Show what would be created without creating

Global Flags:
  -h, --help                   Show this help
      --json                   Output in JSON format
  -q, --quiet                  Suppress non-essential output

Documentation: https://xm.dev/docs/cli/node-create
```

### 4.8 Dangerous Operations

Destructive operations require confirmation or `--force`:

```bash
$ xm node delete xm:entity/acme-api

This will delete node xm:entity/acme-api and all its properties.
12 links reference this node and will become orphaned.

Type the node ID to confirm: xm:entity/acme-api
```

```bash
# Skip confirmation with --force
$ xm node delete xm:entity/acme-api --force

Deleted: xm:entity/acme-api
Orphaned links: 12
```

```bash
# Preview with --dry-run
$ xm node delete xm:entity/acme-api --dry-run

Would delete: xm:entity/acme-api
Would orphan: 12 links
  → xm:uses → xm:entity/fastapi
  → xm:dependsOn → xm:entity/auth-service
  ...
```

### 4.9 Progress and Long-Running Operations

Show progress immediately for operations that may take time:

```bash
$ xm import --format turtle large-dataset.ttl

Importing large-dataset.ttl...
  Parsing:    [████████████████████████████████] 100% (15,234 triples)
  Validating: [████████████████░░░░░░░░░░░░░░░░]  52% (7,921 / 15,234)
  Inserting:  [░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]   0% (waiting...)
```

For non-TTY output (pipes, scripts), progress goes to stderr:

```bash
$ xm import --format turtle large-dataset.ttl --json > result.json
# Progress on stderr, JSON result on stdout
```

Ctrl-C interrupts immediately. Second Ctrl-C skips cleanup.

### 4.10 Stdin/Stdout Composability

Support `-` for stdin/stdout to enable piping:

```bash
# Pipe query results to another command
xm query sparql "SELECT ?s WHERE {?s a xm:Entity}" --json | jq '.results.bindings[].s.value'

# Read SPARQL from stdin
cat query.sparql | xm query sparql -

# Read properties from stdin
echo '{"content": "FastAPI is used"}' | xm node create --type fact --properties -

# Export to stdout, import elsewhere
xm export --format turtle --node xm:entity/acme-api | \
  xm --remote "ocapn:tor:xyz..." import --format turtle -
```

### 4.11 Node Commands

#### `xm node create`

Create a new knowledge node.

```bash
xm node create -t TYPE [-p KEY=VALUE]... [-l PRED:TARGET]... [--properties FILE]

Flags:
  -t, --type TYPE              Node type: entity, fact, session, agent, artifact (required)
  -p, --property KEY=VALUE     Set property (repeatable)
  -l, --link PRED:TARGET       Create link to target (repeatable)
  -g, --graph URI              Target graph (default: session graph or public)
      --properties FILE        Read properties from JSON file (- for stdin)
  -n, --dry-run                Show what would be created without creating

Examples:
  # Create an entity
  xm node create -t entity -p name=acme-api -p kind=repository

  # Create a fact with links
  xm node create -t fact \
    -p "content=Uses FastAPI 0.100+" \
    -l skos:related:xm:entity/acme-api \
    -l xm:confidence:0.95

  # Dry-run to preview
  xm node create -t fact -p "content=Test" --dry-run

  # Read properties from stdin (for complex data)
  echo '{"content": "Complex value with \"quotes\""}' | xm node create -t fact --properties -

# Human output (default)
Created node: xm:node/550e8400-e29b-41d4-a716-446655440000
  Type: fact
  Properties: 1
  Links created: 2

# JSON output (--json)
{
  "ok": true,
  "data": {
    "id": "xm:node/550e8400-e29b-41d4-a716-446655440000",
    "type": "fact",
    "created_at": "2026-01-06T10:30:00Z",
    "properties": {"content": "Uses FastAPI 0.100+"},
    "links_created": 2
  }
}
```

#### `xm node get`

Retrieve a node with its properties and links.

```bash
xm node get NODE_ID [--depth N] [--include-backlinks]

Flags:
      --depth N              Include neighbors up to N hops (default: 0)
  -b, --include-backlinks    Include nodes linking TO this node

Examples:
  # Get single node
  xm node get xm:entity/acme-api

  # Get with immediate neighbors
  xm node get xm:entity/acme-api --depth 1

  # Include backlinks
  xm node get xm:entity/fastapi -b

# Human output shown in section 4.5
# JSON output (--json) includes full structure
```

#### `xm node update`

Update node properties.

```bash
xm node update NODE_ID [-p KEY=VALUE]... [--remove KEY]...

Flags:
  -p, --property KEY=VALUE     Set or update property (repeatable)
  -r, --remove KEY             Remove property (repeatable)
  -n, --dry-run                Show what would change without changing

Examples:
  xm node update xm:entity/acme-api \
    -p last_deploy=2026-01-06 \
    --remove deprecated
```

#### `xm node delete`

Delete a node (requires admin capability). **Dangerous operation.**

```bash
xm node delete NODE_ID [--cascade] [-f|--force] [-n|--dry-run]

Flags:
      --cascade              Also delete orphaned links
  -f, --force                Skip confirmation prompt
  -n, --dry-run              Show what would be deleted without deleting

Examples:
  # Interactive confirmation (default)
  xm node delete xm:entity/acme-api

  # Skip confirmation
  xm node delete xm:entity/acme-api --force

  # Preview what would be deleted
  xm node delete xm:entity/acme-api --dry-run
```

### 4.12 Link Commands

#### `xm link create`

Create a link between nodes.

```bash
xm link create -s SOURCE -p PRED -t TARGET [-P KEY=VALUE]...

Flags:
  -s, --source SOURCE          Source node URI (required)
  -p, --predicate PRED         Predicate URI or prefixed name (required)
  -t, --target TARGET          Target node URI or literal value (required)
  -P, --property KEY=VALUE     Link metadata (repeatable)
  -n, --dry-run                Show what would be created without creating

Examples:
  # Create dependency link
  xm link create -s xm:entity/web-frontend \
    -p xm:dependsOn \
    -t xm:entity/auth-service

  # Supersedes relationship with metadata
  xm link create -s xm:fact/abc123 \
    -p dcterms:replaces \
    -t xm:fact/old456 \
    -P "reason=Updated documentation found"
```

#### `xm link delete`

Remove a link. **Dangerous operation.**

```bash
xm link delete LINK_ID
xm link delete -s SOURCE -p PRED -t TARGET [-f|--force] [-n|--dry-run]

Flags:
  -s, --source SOURCE          Source node URI
  -p, --predicate PRED         Predicate
  -t, --target TARGET          Target node URI
  -f, --force                  Skip confirmation
  -n, --dry-run                Preview without deleting

Examples:
  # Delete by link ID
  xm link delete xm:link/abc123

  # Delete by source-predicate-target
  xm link delete -s xm:entity/web-frontend -p xm:dependsOn -t xm:entity/auth-service
```

### 4.13 Query Commands

#### `xm query sparql`

Execute a SPARQL query (scoped to capability's allowed graphs).

```bash
xm query sparql [QUERY | -] [--cap CAP_REF]

Arguments:
  QUERY                        SPARQL query string (or - for stdin)

Flags:
      --cap REF                Capability for graph access
      --timeout DURATION       Query timeout (default: 30s)
  -o, --output FORMAT          Output format for CONSTRUCT: turtle, ntriples, jsonld

Examples:
  # Public query (auto-scoped to xm:graph/public)
  xm query sparql "SELECT ?framework WHERE { ?framework a xm:Framework }"

  # Query with capability
  xm query sparql --cap xm:cap/abc123 \
    "SELECT ?project ?dep WHERE { ?project xm:dependsOn ?dep }"

  # Read query from file
  xm query sparql - < complex-query.sparql

  # CONSTRUCT with Turtle output
  xm query sparql "CONSTRUCT { ?s ?p ?o } WHERE { ?s xm:uses ?o }" -o turtle

# Human output (default) - tabular format
?project                    ?dep
xm:entity/acme-api        xm:entity/auth-service
xm:entity/web-frontend    xm:entity/acme-api

# JSON output (--json) - SPARQL JSON Results format
{
  "head": {"vars": ["project", "dep"]},
  "results": {
    "bindings": [
      {"project": {"type": "uri", "value": "xm:entity/acme-api"},
       "dep": {"type": "uri", "value": "xm:entity/auth-service"}}
    ]
  }
}
```

**Query Rewriting** (transparent to user):
```
User query:    SELECT ?s WHERE { ?s a xm:Repository }
Capability:    graphs = [xm:graph/public, xm:graph/project/acme-api]
Actual query:  SELECT ?s
               FROM <xm:graph/public>
               FROM <xm:graph/project/acme-api>
               WHERE { ?s a xm:Repository }
```

#### `xm query nodes`

Search for nodes matching criteria (convenience wrapper around SPARQL).

```bash
xm query nodes [-t TYPE] [-p KEY=VALUE]... [--has-link PRED:TARGET] [--limit N] [--since DURATION]

Flags:
  -t, --type TYPE              Filter by node type
  -p, --property KEY=VALUE     Filter by property (repeatable)
      --has-link PRED:TARGET   Filter by outgoing link
      --since DURATION         Only nodes created/modified within duration (e.g., 7d, 24h)
  -l, --limit N                Maximum results (default: 100)

Examples:
  # All entities
  xm query nodes -t entity

  # Entities with specific property
  xm query nodes -t entity -p kind=repository

  # Recent facts
  xm query nodes -t fact --since 7d

  # Nodes using FastAPI
  xm query nodes --has-link xm:uses:xm:entity/fastapi

# Human output (default)
Found 3 nodes:

  xm:entity/acme-api (entity)
    name: acme-api
    kind: repository

  xm:entity/web-frontend (entity)
    name: web-frontend
    kind: application
  ...

# JSON output (--json) - NDJSON for streaming
{"id": "xm:entity/acme-api", "type": "entity", ...}
{"id": "xm:entity/web-frontend", "type": "entity", ...}
```

#### `xm query backlinks`

Find all nodes linking TO a target (Org-roam style).

```bash
xm query backlinks NODE_ID [-p PRED] [--limit N]

Arguments:
  NODE_ID                      Target node to find backlinks for

Flags:
  -p, --predicate PRED         Filter by predicate
  -l, --limit N                Maximum results (default: 100)

Examples:
  # What depends on auth-service?
  xm query backlinks xm:entity/auth-service -p xm:dependsOn

  # All references to a fact
  xm query backlinks xm:fact/abc123
```

#### `xm query path`

Find paths between nodes.

```bash
xm query path --from SOURCE --to TARGET [--max-hops N]

Flags:
  -f, --from SOURCE            Starting node (required)
  -t, --to TARGET              Ending node (required)
      --max-hops N             Maximum path length (default: 5)
      --predicate PRED         Only follow specific predicates

Examples:
  # How is acme-api related to SPEC-022?
  xm query path -f xm:entity/acme-api -t xm:entity/SPEC-022 --max-hops 3

# Human output (default)
Found 1 path (2 hops):

  xm:entity/acme-api
    ← skos:related ←
  xm:entity/SPEC-022

# JSON output (--json)
{
  "paths": [
    [
      {"node": "xm:entity/acme-api"},
      {"link": "skos:related", "direction": "backward"},
      {"node": "xm:entity/SPEC-022"}
    ]
  ]
}
```

#### `xm query context`

Build a token-budgeted context window for an agent.

```bash
xm query context --focus NODE_ID [--max-tokens N] [--include TYPES]...

Flags:
      --focus NODE_ID          Central node for context (required)
      --max-tokens N           Token budget (default: 4000)
      --include TYPES          Node types to include: fact,entity,artifact,decision,research (repeatable)
      --depth N                Maximum traversal depth (default: 2)

Examples:
  # Build context around an entity
  xm query context --focus xm:entity/acme-api \
    --max-tokens 4000 \
    --include fact,entity,artifact

# Human output (default)
Context for xm:entity/acme-api (3,847 / 4,000 tokens)

  Focus: acme-api (repository)

  Related entities (5):
    → uses → FastAPI
    → dependsOn → auth-service
    ...

  Facts (12):
    • Uses FastAPI 0.100+ (confidence: 0.95)
    • OAuth callback URL is /auth/callback (confidence: 0.90)
    ...

# JSON output (--json)
{
  "focus": "xm:entity/acme-api",
  "token_budget": {"max": 4000, "used": 3847},
  "nodes": [...],
  "summary": "Repository with 12 facts, 5 dependencies, 3 artifacts"
}
```

### 4.14 Session Commands

#### `xm session start`

Begin a new session.

```bash
xm session start -a AGENT_ID -p PURPOSE [-c NODE_ID]...

Flags:
  -a, --agent AGENT_ID         Agent identifier (required)
  -p, --purpose DESCRIPTION    Session purpose/description (required)
  -c, --context NODE_ID        Initial context nodes (repeatable)
      --parent SESSION_ID      Parent session for continuations

Examples:
  xm session start -a claude-code \
    -p "Investigate auth bug in web-frontend" \
    -c xm:entity/web-frontend \
    -c xm:entity/auth-service

# Human output (default)
Session started: xm:session/abc123
  Agent: claude-code
  Purpose: Investigate auth bug in web-frontend
  Context: 2 nodes loaded

# JSON output (--json)
{
  "ok": true,
  "data": {
    "session_id": "xm:session/abc123",
    "agent": "claude-code",
    "started_at": "2026-01-06T10:30:00Z",
    "context_nodes": 2
  }
}
```

#### `xm session end`

End the current session.

```bash
xm session end [-s SUMMARY]

Flags:
  -s, --summary TEXT           Session summary (can also be piped via stdin)

Examples:
  xm session end -s "Found OAuth misconfiguration"

  # Summary from stdin
  echo "Found OAuth misconfiguration" | xm session end -s -

# Human output (default)
Session ended: xm:session/abc123
  Duration: 30m 47s
  Nodes created: 5
  Links created: 12

# JSON output (--json)
{
  "ok": true,
  "data": {
    "session_id": "xm:session/abc123",
    "duration_seconds": 1847,
    "nodes_created": 5,
    "links_created": 12,
    "summary": "Found OAuth misconfiguration"
  }
}
```

#### `xm session list`

List sessions.

```bash
xm session list [-a AGENT_ID] [--since DURATION] [--active-only]

Flags:
  -a, --agent AGENT_ID         Filter by agent
      --since DURATION         Only sessions within duration (e.g., 7d)
      --active-only            Only show active (not ended) sessions
  -l, --limit N                Maximum results (default: 20)

Examples:
  xm session list --since 7d
  xm session list -a claude-code --active-only
```

#### `xm session resume`

Resume a previous session.

```bash
xm session resume SESSION_ID

Arguments:
  SESSION_ID                   Session to resume

Examples:
  xm session resume xm:session/abc123

# Restores context and continues linking new discoveries
```

#### `xm session history`

View session activity.

```bash
xm session history [SESSION_ID]

Arguments:
  SESSION_ID                   Session to view (default: current session)

Examples:
  xm session history xm:session/abc123

# Shows nodes/links created during session
```

### 4.15 Capability Commands

#### `xm cap create`

Create a shareable capability.

```bash
xm cap create -g GRAPHS -P PERMS [--expires TIMESTAMP]

Flags:
  -g, --graphs GRAPHS          Comma-separated graph URIs (required)
  -P, --permissions PERMS      Permissions: read, write, admin (required)
      --expires TIMESTAMP      Expiration date (ISO 8601 or duration like 30d)
      --label TEXT             Human-readable label for the capability

Examples:
  # Read-only access to project graph
  xm cap create -g xm:graph/project/acme-api,xm:graph/public \
    -P read \
    --expires 30d

  # Full access with expiration
  xm cap create -g xm:graph/project/acme-api \
    -P read,write \
    --expires 2026-02-01 \
    --label "Contractor access"

# Human output (default)
Created capability: xm:cap/xyz789...
  Graphs: xm:graph/project/acme-api, xm:graph/public
  Permissions: read
  Expires: 2026-02-01

# JSON output (--json)
{
  "ok": true,
  "data": {
    "cap_ref": "xm:cap/xyz789...",
    "graphs": ["xm:graph/project/acme-api", "xm:graph/public"],
    "permissions": ["read"],
    "expires": "2026-02-01T00:00:00Z"
  }
}
```

#### `xm cap attenuate`

Create a weaker capability from an existing one.

```bash
xm cap attenuate CAP_REF [-g GRAPHS] [-P PERMS] [--expires TIMESTAMP]

Arguments:
  CAP_REF                      Parent capability to attenuate

Flags:
  -g, --graphs GRAPHS          Subset of parent's graphs
  -P, --permissions PERMS      Subset of parent's permissions
      --expires TIMESTAMP      Earlier than parent's expiration

Examples:
  # Create read-only version of a read-write cap
  xm cap attenuate xm:cap/abc123 -P read

  # Restrict to single graph with shorter expiry
  xm cap attenuate xm:cap/abc123 \
    -g xm:graph/public \
    --expires 7d
```

#### `xm cap revoke`

Revoke a capability. **Dangerous operation.**

```bash
xm cap revoke CAP_REF [-f|--force]

Arguments:
  CAP_REF                      Capability to revoke

Flags:
  -f, --force                  Skip confirmation

Examples:
  xm cap revoke xm:cap/xyz789
```

#### `xm cap list`

List capabilities.

```bash
xm cap list [--created-by-me] [--expired] [-l LIMIT]

Flags:
      --created-by-me          Only capabilities you created
      --expired                Include expired capabilities
  -l, --limit N                Maximum results (default: 50)

Examples:
  xm cap list
  xm cap list --created-by-me
```

#### `xm cap inspect`

Show details of a capability.

```bash
xm cap inspect CAP_REF

Examples:
  xm cap inspect xm:cap/xyz789
```

### 4.16 Import/Export Commands

#### `xm import`

Import knowledge from various formats.

```bash
xm import -f FORMAT [FILE | -] [-g GRAPH] [-n|--dry-run]

Arguments:
  FILE                         File to import (- for stdin)

Flags:
  -f, --format FORMAT          Format: json, turtle, ntriples, jsonld (required)
  -g, --graph GRAPH            Target graph (default: session graph)
  -n, --dry-run                Validate without importing
      --on-conflict ACTION     How to handle conflicts: skip, replace, fail (default: skip)

Examples:
  # Import RDF Turtle
  xm import -f turtle knowledge.ttl

  # Import from stdin
  cat data.ttl | xm import -f turtle -

  # Import to specific graph
  xm import -f turtle -g xm:graph/project/acme-api data.ttl

  # Dry-run to validate
  xm import -f turtle data.ttl --dry-run

# Shows progress for large imports (see section 4.9)
```

#### `xm export`

Export knowledge graph.

```bash
xm export -f FORMAT [--node NODE_ID] [--depth N] [-o FILE | -]

Flags:
  -f, --format FORMAT          Format: json, turtle, ntriples, jsonld (required)
      --node NODE_ID           Export subgraph rooted at node
      --depth N                Traversal depth for subgraph (default: all)
      --graph GRAPH            Export specific graph only
  -o, --output FILE            Output file (default: stdout, use - explicitly for pipes)

Examples:
  # Export subgraph as Turtle
  xm export -f turtle --node xm:entity/acme-api --depth 2 -o acme-api.ttl

  # Export to stdout for piping
  xm export -f turtle --node xm:entity/acme-api | gzip > backup.ttl.gz

  # Full backup as JSON
  xm export -f json -o backup.json

  # Export specific graph
  xm export -f turtle --graph xm:graph/project/acme-api
```

### 4.17 Synchronization Commands

#### `xm subscribe`

Subscribe to real-time change notifications (streaming NDJSON).

```bash
xm subscribe [--cap CAP_REF] [-g GRAPHS] [--events TYPES]

Flags:
      --cap CAP_REF            Capability for graph access (public if omitted)
  -g, --graphs GRAPHS          Comma-separated graph URIs (all accessible if omitted)
      --events TYPES           Event types: insert, delete, all (default: all)
      --since CURSOR           Resume from cursor position
      --replay                 Replay all events from beginning

Examples:
  # Subscribe to all changes
  xm subscribe --cap xm:cap/abc123

  # Subscribe to specific graph
  xm subscribe --cap xm:cap/abc123 -g xm:graph/project/acme-api

  # Inserts only
  xm subscribe --cap xm:cap/abc123 --events insert

# Output (streaming NDJSON to stdout, Ctrl-C to stop):
{"seq":1001,"event":"insert","graph":"xm:graph/project/acme-api","triple":{...},"timestamp":"...","agent":"claude-code"}
{"seq":1002,"event":"delete","graph":"xm:graph/project/acme-api","triple":{...},"timestamp":"...","agent":"gpt-4"}
```

#### `xm sync`

Synchronize local changes with a remote xm daemon.

```bash
xm sync --target URI [--direction DIR] [-n|--dry-run]

Flags:
      --target URI             Remote server sturdyref: ocapn:tor:... or ocapn:tcp:... (required)
      --direction DIR          push, pull, or both (default: both)
  -n, --dry-run                Show what would be synced without applying
  -v, --verbose                Show detailed sync progress

Examples:
  # Full bidirectional sync
  xm sync --target "ocapn:tor:xyz123...#swiss-num"

  # Push local changes only
  xm sync --target "ocapn:tor:xyz123..." --direction push

  # Preview sync
  xm sync --target "ocapn:tor:xyz123..." --dry-run

# Human output (default)
Syncing with ocapn:tor:xyz123...
  Pushed: 42 triples to 1 graph
  Pulled: 17 triples from 1 graph
  Conflicts: 0

# JSON output (--json)
{
  "ok": true,
  "data": {
    "pushed": {"triples": 42, "graphs": ["xm:graph/session/abc123"]},
    "pulled": {"triples": 17, "graphs": ["xm:graph/project/acme-api"]},
    "conflicts": []
  }
}
```

### 4.17 Daemon Commands

xm uses an **embedded daemon** architecture. The daemon auto-starts on first CLI invocation and runs in the background, managing the store, event journal, and OCapN listeners.

#### Daemon Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              xm Daemon                                      │
│                                                                              │
│   Auto-starts on first CLI command, runs in background                      │
│                                                                              │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│   │   Oxigraph  │  │   Event     │  │   Graph     │  │   OCapN     │       │
│   │   Store     │  │   Journal   │  │ Gatekeeper  │  │  Listeners  │       │
│   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                                              │
│   Unix Socket: ~/.local/share/xm/daemon.sock                                │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
         ┌─────────────────────────────┼─────────────────────────────────────┐
         │                             │                                      │
         ▼                             ▼                                      ▼
┌─────────────────┐         ┌─────────────────┐                   ┌─────────────────┐
│  xm node create │         │  xm query ...   │                   │  Remote Agent   │
│  (CLI command)  │         │  (CLI command)  │                   │  (via OCapN)    │
└─────────────────┘         └─────────────────┘                   └─────────────────┘
```

**Auto-start behavior**:
- First `xm` command checks for daemon via Unix socket
- If not running, daemon starts automatically in background
- Daemon writes PID to `~/.local/share/xm/daemon.pid`
- CLI command proceeds once daemon is ready

#### `xm daemon`

Manage the xm daemon.

```bash
xm daemon <subcommand>

Subcommands:
  start          Start daemon (usually automatic)
  stop           Stop the daemon
  restart        Restart the daemon
  status         Show daemon status

Examples:
# Check daemon status
xm daemon status

# Output (human):
Daemon Status
  PID:        12345
  Uptime:     3h 42m
  Store:      ~/.local/share/xm
  Socket:     ~/.local/share/xm/daemon.sock
  Memory:     45 MB

  Listeners:
    unix    ~/.local/share/xm/daemon.sock (local CLI)
    tor     abc123...onion (remote agents)

# Output (--json):
{
  "ok": true,
  "data": {
    "pid": 12345,
    "uptime_seconds": 13320,
    "store_path": "~/.local/share/xm",
    "socket_path": "~/.local/share/xm/daemon.sock",
    "memory_mb": 45,
    "listeners": [
      {"transport": "unix", "address": "~/.local/share/xm/daemon.sock"},
      {"transport": "tor", "address": "abc123...onion"}
    ]
  }
}

# Stop daemon gracefully
xm daemon stop

# Force restart (e.g., after config change)
xm daemon restart
```

#### `xm listen`

Add a network listener for remote agent access. Requires running daemon.

```bash
xm listen [--transport TRANSPORT] [--port PORT]

Options:
  --transport    tor | tcp | unix (default: tor)
  --port         Port for TCP transport (default: 8470)

Examples:
# Add Tor hidden service listener (most secure, persistent)
xm listen --transport tor

# Output:
Listener Added
  Transport:  tor
  Address:    abc123xyz...onion
  Sturdyref:  ocapn:tor:abc123xyz...onion#swiss-num-here

  Share this sturdyref with agents that need remote access.
  The Tor address persists across daemon restarts.

# Add TCP listener (faster, less private)
xm listen --transport tcp --port 8470

# Output:
Listener Added
  Transport:  tcp
  Address:    192.168.1.100:8470
  Sturdyref:  ocapn:tcp:192.168.1.100:8470#swiss-num-here

  ⚠ TCP exposes your IP address. Use Tor for privacy.
```

#### `xm listeners`

List active network listeners.

```bash
xm listeners

# Output:
Active Listeners
  TRANSPORT  ADDRESS                      STURDYREF
  unix       ~/.local/share/xm/daemon.sock  (local only)
  tor        abc123xyz...onion            ocapn:tor:abc123...#swiss
  tcp        192.168.1.100:8470           ocapn:tcp:192.168...#swiss
```

#### Daemon Configuration

Daemon behavior is configured in `~/.config/xm/daemon.toml`:

```toml
# ~/.config/xm/daemon.toml

[daemon]
# Auto-start daemon on first CLI command (default: true)
auto_start = true

# Idle timeout - stop daemon after inactivity (default: never)
# idle_timeout = "1h"

# Log level: error, warn, info, debug, trace
log_level = "info"

[listeners]
# Start these listeners automatically when daemon starts
auto_start = ["unix"]

# Tor listener (persistent hidden service)
[listeners.tor]
enabled = false        # Enable with: xm listen --transport tor
persistent = true      # Reuse same .onion address across restarts

# TCP listener
[listeners.tcp]
enabled = false
port = 8470
bind = "0.0.0.0"      # Use "127.0.0.1" for local-only
```

---

## 5. Data Models

### 5.1 Guile Scheme Definitions

```scheme
;;; xm/types.scm - Core type definitions

(use-modules (goblins)
             (goblins actor-lib cell)
             (srfi srfi-19))  ; Date/time

;;; Node structure
(define-record-type <xm-node>
  (make-xm-node id type created-at updated-at properties provenance)
  xm-node?
  (id xm-node-id)
  (type xm-node-type)
  (created-at xm-node-created-at)
  (updated-at xm-node-updated-at set-xm-node-updated-at!)
  (properties xm-node-properties set-xm-node-properties!)
  (provenance xm-node-provenance))

;;; Link structure
(define-record-type <xm-link>
  (make-xm-link id source predicate target created-at provenance properties)
  xm-link?
  (id xm-link-id)
  (source xm-link-source)
  (predicate xm-link-predicate)
  (target xm-link-target)
  (created-at xm-link-created-at)
  (provenance xm-link-provenance)
  (properties xm-link-properties))

;;; Provenance metadata
(define-record-type <provenance>
  (make-provenance source confidence method agent-id timestamp)
  provenance?
  (source provenance-source)           ; URI or description
  (confidence provenance-confidence)   ; 0.0-1.0
  (method provenance-method)           ; 'direct | 'inferred | 'imported
  (agent-id provenance-agent-id)
  (timestamp provenance-timestamp))

;;; Session structure
(define-record-type <xm-session>
  (make-xm-session id agent-id purpose started-at ended-at
                     context discoveries parent)
  xm-session?
  (id xm-session-id)
  (agent-id xm-session-agent-id)
  (purpose xm-session-purpose)
  (started-at xm-session-started-at)
  (ended-at xm-session-ended-at set-xm-session-ended-at!)
  (context xm-session-context set-xm-session-context!)
  (discoveries xm-session-discoveries set-xm-session-discoveries!)
  (parent xm-session-parent))
```

### 5.2 URI Scheme

xm uses URIs from standard vocabularies where possible, with `xm:` namespace for identifiers and custom predicates.

**Resource Identifiers** (xm namespace):

```
https://xm.dev/ns/v1#{type}/{id}

Types:
  xm:node/{uuid}     - Knowledge node
  xm:link/{uuid}     - Relationship link
  xm:session/{uuid}  - Session
  xm:agent/{name}    - Agent identity
  xm:cap/{token}     - Capability reference
  xm:entity/{slug}   - Named entity (human-friendly)
```

**Predicates** (standard namespaces preferred):

```
Standard (use these when applicable):
  prov:wasGeneratedBy      - Entity generated by activity
  prov:wasAttributedTo     - Entity attributed to agent
  prov:hadPrimarySource    - Primary source reference
  dcterms:created          - Creation timestamp
  dcterms:modified         - Modification timestamp
  dcterms:replaces         - Supersedes relationship
  skos:related             - Generic relationship
  rdfs:label               - Human-readable name
  rdfs:comment             - Description

xm-specific (when no standard exists):
  xm:uses                - Technology/framework usage
  xm:dependsOn           - Software dependency
  xm:confidence          - Confidence score (0.0-1.0)
```

### 5.3 JSON Wire Format

All CLI output follows this envelope:

```json
{
  "ok": true,
  "data": { ... },
  "meta": {
    "timestamp": "2026-01-06T10:30:00Z",
    "session_id": "xm:session/abc123",
    "request_id": "req-xyz789"
  }
}
```

Error format:

```json
{
  "ok": false,
  "error": {
    "code": "NODE_NOT_FOUND",
    "message": "Node xm:entity/xyz not found",
    "details": { ... }
  },
  "meta": { ... }
}
```

---

## 6. Goblins Actor Architecture

### 6.1 Oxigraph FFI Bindings

```scheme
;;; xm/oxigraph-ffi.scm - FFI bindings to Oxigraph

(use-modules (system foreign)
             (system foreign-library))

;; Load the Oxigraph C library (built from Rust with cbindgen)
(define libxm-oxigraph
  (load-foreign-library "libxm_oxigraph"))

;; FFI function bindings
(define oxigraph-store-open
  (foreign-library-function libxm-oxigraph "xm_store_open"
    #:return-type '*
    #:arg-types (list '*)))  ; path string

(define oxigraph-store-query
  (foreign-library-function libxm-oxigraph "xm_store_query"
    #:return-type '*
    #:arg-types (list '* '*)))  ; store, sparql string

(define oxigraph-store-update
  (foreign-library-function libxm-oxigraph "xm_store_update"
    #:return-type int
    #:arg-types (list '* '*)))  ; store, sparql update string

(define oxigraph-results-to-json
  (foreign-library-function libxm-oxigraph "xm_results_to_json"
    #:return-type '*
    #:arg-types (list '*)))  ; results pointer

;; High-level Scheme wrappers
(define (make-oxigraph-store path)
  (oxigraph-store-open (string->pointer path)))

(define (oxigraph-query store sparql)
  (let* ((results (oxigraph-store-query store (string->pointer sparql)))
         (json-ptr (oxigraph-results-to-json results)))
    (pointer->string json-ptr)))

(define (oxigraph-update! store sparql)
  (oxigraph-store-update store (string->pointer sparql)))
```

### 6.2 Graph Gatekeeper Actor

The **Graph Gatekeeper** is the security boundary—all Oxigraph access passes through it.

```scheme
;;; xm/gatekeeper.scm - Security layer for graph access

(use-modules (goblins)
             (goblins actor-lib cell)
             (xm-oxigraph-ffi)
             (xm capabilities))

;;; Graph Gatekeeper Actor - ALL storage access goes through here
(define (^graph-gatekeeper bcom oxigraph-store cap-store)

  ;; Validate capability and return allowed graphs
  (define (validate-capability cap-ref required-permission)
    (let ((cap (bloblin-get cap-store cap-ref)))
      (unless cap
        (error 'invalid-capability "Unknown capability reference" cap-ref))
      ;; Check expiration
      (when (and (cap-expires cap)
                 (time>? (current-time) (cap-expires cap)))
        (error 'expired-capability "Capability has expired" cap-ref))
      ;; Check permission
      (unless (memq required-permission (cap-permissions cap))
        (error 'permission-denied
               (format #f "Capability lacks ~a permission" required-permission)))
      ;; Return allowed graphs
      (cap-graphs cap)))

  ;; Rewrite SPARQL query to scope to allowed graphs
  (define (scope-query sparql-string allowed-graphs)
    (let ((from-clauses
           (string-join
            (map (lambda (g) (format #f "FROM <~a>" g)) allowed-graphs)
            "\n")))
      ;; Insert FROM clauses after SELECT/CONSTRUCT/etc.
      (sparql-add-from-clauses sparql-string from-clauses)))

  (methods
   ;; Query with capability (or public-only if no cap)
   [(query cap-ref sparql-string)
    (let* ((allowed-graphs
            (if cap-ref
                (validate-capability cap-ref 'read)
                '("xm:graph/public")))  ; public only if no cap
           (scoped-sparql (scope-query sparql-string allowed-graphs)))
      ;; Execute against Oxigraph
      (oxigraph-query oxigraph-store scoped-sparql))]

   ;; Insert data (requires write permission)
   [(insert cap-ref graph-uri triples-turtle)
    (let ((allowed-graphs (validate-capability cap-ref 'write)))
      ;; Verify target graph is allowed
      (unless (member graph-uri allowed-graphs)
        (error 'permission-denied
               "Capability does not grant write access to graph" graph-uri))
      ;; Execute SPARQL UPDATE
      (oxigraph-update! oxigraph-store
        (format #f "INSERT DATA { GRAPH <~a> { ~a } }"
                graph-uri triples-turtle)))]

   ;; Delete data (requires admin permission)
   [(delete cap-ref graph-uri pattern)
    (let ((allowed-graphs (validate-capability cap-ref 'admin)))
      (unless (member graph-uri allowed-graphs)
        (error 'permission-denied
               "Capability does not grant admin access to graph" graph-uri))
      (oxigraph-update! oxigraph-store
        (format #f "DELETE WHERE { GRAPH <~a> { ~a } }"
                graph-uri pattern)))]

   ;; Attenuate capability (can only weaken, never strengthen)
   [(attenuate cap-ref new-graphs new-permissions new-expires)
    (let* ((parent-cap (bloblin-get cap-store cap-ref))
           (parent-graphs (cap-graphs parent-cap))
           (parent-perms (cap-permissions parent-cap)))
      ;; Verify attenuation (subset only)
      (unless (lset<= string=? new-graphs parent-graphs)
        (error 'invalid-attenuation
               "Cannot grant graphs not in parent capability"))
      (unless (lset<= eq? new-permissions parent-perms)
        (error 'invalid-attenuation
               "Cannot grant permissions not in parent capability"))
      ;; Create child capability
      (let ((child-cap (make-xm-capability
                        (generate-sturdyref)
                        new-graphs
                        new-permissions
                        new-expires
                        cap-ref)))  ; link to parent for audit
        (bloblin-put! cap-store (cap-id child-cap) child-cap)
        (cap-id child-cap)))]))
```

### 6.3 Vat Organization

```scheme
;;; xm/vats.scm - Vat setup and initialization

(use-modules (goblins)
             (goblins vat)
             (xm-oxigraph-ffi)
             (xm-gatekeeper))

;;; Main Vat: coordinates all actors
(define (spawn-xm-vat config)
  (define vat (spawn-vat #:name "xm-main"))

  (with-vat vat
    ;; Initialize Oxigraph store
    (define oxigraph-store
      (make-oxigraph-store (config-oxigraph-path config)))

    ;; Initialize Bloblin stores
    (define cap-store
      (make-bloblin-store (config-capabilities-path config)))
    (define session-store
      (make-bloblin-store (config-sessions-path config)))
    (define audit-store
      (make-bloblin-store (config-audit-path config)))

    ;; Spawn actors
    (define gatekeeper
      (spawn ^graph-gatekeeper oxigraph-store cap-store))
    (define session-actor
      (spawn ^session-actor gatekeeper session-store))

    ;; Return actor references
    (values gatekeeper session-actor)))

;;; Session Vat: manages sessions and context
(define (spawn-session-vat store-path)
  (spawn-vat
   #:name "xm-sessions"
   #:persist? #t
   #:storage-backend (make-bloblin-backend store-path)))

;;; Session Actor
(define (^session-actor bcom graph-ref)
  (define sessions (make-hash-table))
  (define current-session #f)

  (methods
   [(start agent-id purpose context-nodes)
    (let* ((id (generate-session-uri))
           (session (make-xm-session id agent-id purpose
                                       (current-time) #f
                                       context-nodes '() #f)))
      (hash-set! sessions id session)
      (set! current-session session)
      id)]

   [(end summary)
    (when current-session
      (set-xm-session-ended-at! current-session (current-time))
      ;; Create session summary node and link discoveries
      (let ((summary-node ($ graph-ref 'create-node
                             'artifact
                             `((content . ,summary))
                             (current-provenance))))
        (for-each
         (lambda (node-id)
           ($ graph-ref 'create-link node-id
              "prov:wasGeneratedBy"
              (xm-session-id current-session)
              '() (current-provenance)))
         (xm-session-discoveries current-session)))
      (let ((ended (xm-session-id current-session)))
        (set! current-session #f)
        ended))]

   [(record-discovery node-id)
    (when current-session
      (set-xm-session-discoveries!
       current-session
       (cons node-id (xm-session-discoveries current-session))))]))

;;; Capability Vat: manages access control
(define (^capability-actor bcom graph-ref)
  (define caps (make-hash-table))

  (methods
   [(create-cap node-id permissions scope expires)
    (let* ((token (generate-cap-token))
           (cap-ref (string-append "xm:cap/" token)))
      ;; Create a facet of the graph actor with limited permissions
      (hash-set! caps cap-ref
                 (make-capability-facet graph-ref node-id
                                        permissions scope expires))
      cap-ref)]

   [(use-cap cap-ref)
    (hash-ref caps cap-ref #f)]

   [(revoke-cap cap-ref)
    (hash-remove! caps cap-ref)]))
```

### 6.2 Transactional Safety

Goblins provides transactional semantics:

```scheme
;; All operations within a turn are atomic
;; If an error occurs, the vat state rolls back

(define (safe-multi-create graph-ref nodes-spec)
  ;; Either all nodes are created, or none are
  (with-vat graph-vat
    (map (lambda (spec)
           ($ graph-ref 'create-node
              (assoc-ref spec 'type)
              (assoc-ref spec 'properties)
              (assoc-ref spec 'provenance)))
         nodes-spec)))
```

---

## 7. Implementation Phases

### Phase 1: Oxigraph FFI Foundation (Storage Layer)

**Deliverables**:

- [ ] Rust crate `xm-oxigraph` wrapping Oxigraph with C ABI
- [ ] `cbindgen` configuration for C header generation
- [ ] Guile FFI bindings to `libxm_oxigraph`
- [ ] Basic store operations: open, query, update, close
- [ ] Integration tests: Guile → FFI → Oxigraph → RocksDB

**Acceptance Criteria**:

- [ ] SPARQL SELECT queries return JSON results to Guile
- [ ] SPARQL UPDATE inserts data visible to subsequent queries
- [ ] Store persists across process restarts
- [ ] No memory leaks in FFI boundary

### Phase 2: OCapN Netlayer (Network Layer)

**Rationale**: OCapN is essential infrastructure since LLM agents are inherently distributed (Claude on Anthropic, GPT on OpenAI, local models on user machines). Building the network layer early ensures capabilities work identically locally and remotely.

**Deliverables**:

- [ ] Goblins netlayer configuration
- [ ] CapTP protocol initialization
- [ ] Sturdyref generation and resolution
- [ ] Transport selection (Tor onion / TCP+TLS / Unix socket)
- [ ] Basic remote actor reference passing
- [ ] Integration tests: cross-vat capability invocation

**Acceptance Criteria**:

- [ ] Sturdyrefs resolve to correct actors across process restarts
- [ ] Capabilities can be shared between local processes
- [ ] Encrypted transport (TLS) functional
- [ ] Promise pipelining reduces round-trips

### Phase 3: Graph Gatekeeper & Capabilities (Security Layer)

**Deliverables**:

- [ ] Capability data model with graph scoping
- [ ] Bloblin store for capabilities
- [ ] Graph Gatekeeper actor implementation
- [ ] Query rewriting with FROM clause injection
- [ ] Capability attenuation logic
- [ ] Remote capability validation via OCapN
- [ ] CLI: `xm cap create|attenuate|revoke|list`

**Acceptance Criteria**:

- [ ] Queries without capability see only `xm:graph/public`
- [ ] Queries with capability see exactly allowed graphs
- [ ] Attenuated capabilities cannot exceed parent permissions
- [ ] Expired capabilities correctly rejected
- [ ] Remote agents can use attenuated capabilities via sturdyrefs

### Phase 4: CLI & SPARQL Interface

**Deliverables**:

- [ ] CLI framework (Guile script or compiled binary)
- [ ] `xm query sparql` with automatic scoping
- [ ] `xm node create|get|update|delete` (convenience wrappers)
- [ ] `xm link create|delete`
- [ ] JSON output envelope with metadata
- [ ] NDJSON streaming for large results
- [ ] `--remote` flag for OCapN connection to remote xm daemon

**Acceptance Criteria**:

- [ ] All CLI output parseable by JSON tools
- [ ] SPARQL queries complete within 100ms for 10K triples
- [ ] Error messages include actionable details
- [ ] CLI can operate against local or remote store

### Phase 5: Session Management

**Deliverables**:

- [ ] Session actor with start/end lifecycle
- [ ] Session-scoped named graph (`xm:graph/session/{id}`)
- [ ] Automatic `prov:wasGeneratedBy` linking
- [ ] Session resume with context restoration
- [ ] Remote session handoff (transfer session to another agent)
- [ ] CLI: `xm session start|end|list|resume|history`

**Acceptance Criteria**:

- [ ] Session state persists across CLI invocations
- [ ] Nodes created in session auto-link to session graph
- [ ] Session graphs isolated from other sessions
- [ ] Sessions can be resumed by remote agents with proper capability

### Phase 6: Import/Export & Federation

**Deliverables**:

- [ ] RDF Turtle import/export (via Oxigraph)
- [ ] N-Triples import/export
- [ ] JSON-LD import/export
- [ ] Graph-scoped export (export only allowed graphs)
- [ ] Cross-machine graph federation (federated SPARQL)
- [ ] Capability delegation across federation peers
- [ ] CLI: `xm import|export|federate`

**Acceptance Criteria**:

- [ ] Round-trip Turtle export/import preserves all data
- [ ] Export respects capability scoping
- [ ] Imported data placed in specified target graph
- [ ] Federated queries span multiple trusted xm daemons
- [ ] Capability revocation propagates to remote holders

---

## 8. Security Considerations

### 8.1 Local Security

- Store directory permissions: `0700` (user-only)
- No secrets in node properties (warn on patterns)
- Capability tokens: cryptographically random, 256-bit

### 8.2 Capability Security

- Object capabilities are unforgeable references
- No ambient authority; all access via explicit caps
- Capabilities attenuate (can only reduce permissions)
- Revocation is immediate and complete

### 8.3 Agent Trust

- Agent IDs are self-declared (no verification by default)
- Provenance tracks which agent created each fact
- Confidence scores indicate trust level
- No automatic trust elevation

### 8.4 Data Privacy

- All storage is local (no telemetry)
- Export requires explicit user action
- Future: OCapN uses encrypted transport

### 8.5 Multi-Agent Isolation

When multiple agents operate from the same environment (same machine, same user account), capability boundaries are maintained through **invoker-mediated provisioning**:

**The Human as Root of Trust**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Human (Root Capability Holder)                        │
│                                                                              │
│   Holds: xm:cap/root-abc123 (admin access to all graphs)                    │
│                                                                              │
│   Before invoking any agent, human creates attenuated capabilities:         │
│                                                                              │
│   xm cap create --cap xm:cap/root-abc123 \                                  │
│     --graphs "xm:graph/project/acme-api,xm:graph/session/claude-*" \        │
│     --permissions read,write \                                               │
│     --label "Claude session capability"                                      │
│   # Output: xm:cap/claude-def456                                            │
│                                                                              │
│   xm cap create --cap xm:cap/root-abc123 \                                  │
│     --graphs "xm:graph/project/acme-api" \                                  │
│     --permissions read \                                                     │
│     --label "GPT read-only capability"                                       │
│   # Output: xm:cap/gpt-ghi789                                               │
└──────────────────────────────┬──────────────────────────────────────────────┘
                               │
           ┌───────────────────┴───────────────────┐
           │                                       │
           ▼                                       ▼
┌─────────────────────────┐           ┌─────────────────────────┐
│      Claude Code        │           │      GPT Agent          │
│                         │           │                         │
│  Receives only:         │           │  Receives only:         │
│  --cap xm:cap/claude-*  │           │  --cap xm:cap/gpt-*     │
│                         │           │                         │
│  Can access:            │           │  Can access:            │
│  • acme-api (r/w)       │           │  • acme-api (read-only) │
│  • own session graphs   │           │  • public graphs        │
└─────────────────────────┘           └─────────────────────────┘
```

**Key Principles**:

1. **No shared capability storage**: Agents receive capabilities via `--cap` argument at invocation, never from shared files or environment variables

2. **Capability per invocation**: Each agent session gets a unique, attenuated capability. Even if Agent A learns Agent B's capability reference, the reference is cryptographically unforgeable

3. **Session-scoped capabilities**: Agents can create session graphs (`xm:graph/session/{agent}-{id}`) but cannot access other agents' session graphs unless explicitly granted

4. **Audit trail**: All capabilities track `created-by` (parent capability), enabling forensic analysis of capability delegation chains

**Orchestration Layer Integration**:

For programmatic multi-agent orchestration, the orchestration layer (not the agents) holds the root capability and provisions each agent:

```python
# Orchestration layer (pseudocode)
root_cap = "xm:cap/root-abc123"

# Create per-agent capabilities
claude_cap = xm_cap_create(
    parent=root_cap,
    graphs=["xm:graph/project/acme-api", "xm:graph/session/claude-*"],
    permissions=["read", "write"]
)

gpt_cap = xm_cap_create(
    parent=root_cap,
    graphs=["xm:graph/project/acme-api"],
    permissions=["read"]
)

# Invoke agents with their specific capabilities
invoke_claude(f"--cap {claude_cap}")
invoke_gpt(f"--cap {gpt_cap}")
```

**What This Prevents**:

| Threat | Mitigation |
|--------|------------|
| Agent A uses Agent B's capability | Capabilities are 256-bit random; no shared storage means no access |
| Agent escalates permissions | Capabilities can only attenuate, never strengthen |
| Agent accesses ungranted graphs | Graph Gatekeeper rejects queries to non-allowed graphs |
| Revoked capability still used | Revocation is immediate; sturdyref becomes invalid |

---

## 9. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Query latency (single node) | <50ms | Time for `xm node get` |
| Query latency (backlinks) | <100ms | Time for `xm query backlinks` |
| Storage efficiency | <1KB/node avg | Total storage / node count |
| Agent compatibility | 100% | Agents successfully parse output |
| Persistence reliability | 100% | Data survives clean restarts |
| Capability correctness | 100% | Unauthorized ops correctly rejected |

---

## 10. Traceability

### External References

**Core Technologies**:

- [Spritely Goblins 0.17.0 Manual](https://files.spritely.institute/docs/guile-goblins/0.17.0/index.html) - Security layer, capabilities, actors
- [OCapN Specification](https://github.com/ocapn/ocapn) - Network layer, CapTP protocol
- [Oxigraph](https://github.com/oxigraph/oxigraph) - SPARQL graph database (storage layer)
- [Object-Capability Model](https://en.wikipedia.org/wiki/Object-capability_model)
- [cbindgen](https://github.com/mozilla/cbindgen) - Rust to C bindings generator

**Semantic Web Vocabularies**:

- [RDF 1.1 Concepts](https://www.w3.org/TR/rdf11-concepts/) - Resource Description Framework
- [PROV-O: The PROV Ontology](https://www.w3.org/TR/prov-o/) - Provenance vocabulary
- [Dublin Core Terms](https://www.dublincore.org/specifications/dublin-core/dcmi-terms/) - Metadata vocabulary
- [SKOS Reference](https://www.w3.org/TR/skos-reference/) - Knowledge organization vocabulary
- [RDF Schema](https://www.w3.org/TR/rdf-schema/) - Basic ontology vocabulary

**Inspiration**:

- [Org-roam](https://www.orgroam.com/) - Backlinks and knowledge graph patterns

### Implementation

- Repository: `xm` (new)
- Language: Guile Scheme 3.0+
- Primary dependency: Spritely Goblins 0.17.0

---

## Document History

| Version | Date | Author | Changes |
|---|---|---|---|
| 0.1.0 | 2026-01-06 | Digital Services Team | Initial draft |
| 0.2.0 | 2026-01-06 | Digital Services Team | Adopted standard vocabularies (PROV-O, Dublin Core, SKOS); minimized custom xm: namespace |
| 0.3.0 | 2026-01-06 | Digital Services Team | Integrated Oxigraph via FFI for SPARQL storage; added named graphs for capability scoping; two-layer architecture (Goblins security + Oxigraph storage) |
| 0.4.0 | 2026-01-06 | Digital Services Team | Elevated OCapN to core infrastructure (Phase 2); three-layer architecture (OCapN network + Goblins security + Oxigraph storage); added remote capability validation, remote session handoff, and federation features to implementation phases |
| 0.5.0 | 2026-01-06 | Digital Services Team | Added Section 3.7 State Synchronization using Goblins-native primitives (sturdyrefs, pubsub, promise pipelining); added CLI commands for subscribe and sync; documented conflict resolution and offline operation |
| 0.6.0 | 2026-01-06 | Digital Services Team | Added Section 3.8 Store-and-Forward Messaging with Event Journal, Subscription Cursors, Outbox for offline mutations, reliable delivery protocol, and journal compaction |
| 0.7.0 | 2026-01-06 | Digital Services Team | Renamed from Meld to Cross Memory (xm); updated CLI tool name, URI namespace (xm:), environment variables (XM_*), and all references throughout |
| 0.8.0 | 2026-01-06 | Digital Services Team | Added Section 8.5 Multi-Agent Isolation documenting invoker-mediated capability provisioning, per-agent capability boundaries, orchestration layer integration, and threat mitigations |
| 0.9.0 | 2026-01-06 | Digital Services Team | Replaced `xm server` with embedded daemon architecture; daemon auto-starts on first CLI command; added `xm daemon`, `xm listen`, `xm listeners` commands; added daemon.toml configuration |

---

**END OF SPECIFICATION**
