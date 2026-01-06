# xm Implementation Status vs SPEC-029

## Phase 1: Storage Layer - COMPLETE

- [x] Oxigraph FFI crate (`oxigraph-ffi/src/lib.rs`)
- [x] Guile FFI bindings (`guile/xm/store.scm`)
- [x] SPARQL query/update support
- [x] N-Quads persistence (file-based workaround for RocksDB ARM64 crash)
- [x] Named graph support (quad model)

## Phase 2: CLI Foundation - COMPLETE

- [x] Argument parser (`guile/xm/cli/parser.scm`)
- [x] JSON/human output formatting (`guile/xm/cli/output.scm`)
- [x] Vocabulary/namespace handling (`guile/xm/vocabulary.scm`)
- [x] Main entry point (`guile/xm/main.scm`)
- [x] Makefile with build/test/install

## Phase 3: Node Commands - COMPLETE

- [x] `xm node create` - create nodes with type/properties
- [x] `xm node get` - retrieve node with properties
- [x] `xm node update` - update node properties
- [x] `xm node delete` - delete nodes

## Phase 4: Link Commands - COMPLETE

- [x] `xm link create` - create typed links with metadata
- [x] `xm link get` - retrieve link details
- [x] `xm link list` - list/filter links
- [x] `xm link delete` - delete links

## Phase 5: Query Commands - COMPLETE

- [x] `xm query sparql` - raw SPARQL queries
- [x] `xm query nodes` - search nodes by criteria
- [x] `xm query backlinks` - Org-roam style backlinks
- [x] `xm query path` - path finding (basic)

---

## Outstanding Implementation Tasks

### Phase 6: Schema Commands - COMPLETE

Per SPEC-029 Section 5.14:

- [x] `xm schema classes` - list known node types
- [x] `xm schema predicates` - list predicates with usage stats
- [x] `xm schema describe` - show schema info for a class/predicate

### Phase 7: Graph Commands - NOT IMPLEMENTED

Per SPEC-029 Section 5.15:

- [ ] `xm graph list` - list named graphs with stats
- [ ] `xm graph create` - create new named graph
- [ ] `xm graph drop` - delete named graph
- [ ] `xm graph stats` - detailed graph statistics

### Phase 8: Import/Export Commands - NOT IMPLEMENTED

Per SPEC-029 Section 5.18:

- [ ] `xm import` - import from Turtle/N-Triples/JSON-LD files
- [ ] `xm export` - export to RDF formats with graph selection

### Phase 9: Session Commands - STUB ONLY

Per SPEC-029 Section 5.16 (CLI structure exists but not functional):

- [ ] Wire `session start` to actually create session nodes in store
- [ ] Wire `session end` to record session summary and discoveries
- [ ] Wire `session list` to query sessions from store
- [ ] Wire `session resume` to reload session context
- [ ] Wire `session history` to show session discoveries
- [ ] Implement automatic session linking (discoveries -> session)

### Phase 10: Capability Commands - COMPLETE

Per SPEC-029 Section 5.17:

- [x] `cap create` - store capability with graphs/permissions in RDF store
- [x] `cap attenuate` - create child capability with subset validation
- [x] `cap revoke` - revoke capability (marks as revoked in store)
- [x] `cap list` - query capabilities from store
- [x] `cap inspect` - show full capability details
- [x] `cap export` - export as local token or OCapN sturdyref (when daemon running)
- [x] `cap import` - import from token or sturdyref
- [x] Implement capability-enforced queries (`--cap` flag on `xm query sparql`)
- [x] Query rewriting with FROM clause scoping for allowed graphs

### Phase 11: Daemon Commands - IN PROGRESS

Per SPEC-029 Section 5.20:

- [x] Implement daemon process with PID management
- [x] Unix socket IPC for CLI->daemon JSON-RPC communication
- [x] `daemon start` - spawn Goblins vat (foreground mode works)
- [x] `daemon stop` - graceful shutdown
- [x] `daemon restart` - stop+start
- [x] `daemon status` - show running state
- [x] Goblins runtime initialization with ^cap-registry actor
- [ ] OCapN tcp-tls netlayer (blocked by macOS fibers compatibility)
- [ ] `daemon listen` - add OCapN listener
- [ ] `daemon listeners` - list active listeners

### Phase 12: Synchronization Commands - NOT IMPLEMENTED

Per SPEC-029 Section 5.19:

- [ ] `xm subscribe` - real-time change notifications (NDJSON stream)
- [ ] `xm sync` - sync with remote xm daemon via OCapN

### Phase 13: Store Commands - NOT IMPLEMENTED

Per SPEC-029 Section 5.21:

- [ ] `xm store compact` - optimize storage
- [ ] `xm store backup` - backup store to file
- [ ] `xm store restore` - restore from backup
- [ ] `xm store info` - storage statistics

---

## Architecture Components

### Goblins Integration - IN PROGRESS

- [x] Integrate Spritely Goblins 0.16.1 actor model (via Homebrew)
- [x] `^cap-registry` actor for capability label->actor mapping
- [x] Runtime vat initialization in daemon
- [ ] `^graph-gatekeeper` actor for security enforcement
- [ ] `^capability-store` actor with Bloblin persistence
- [ ] `^session-actor` for session lifecycle
- [ ] `^event-journal` for append-only mutation log
- [ ] `^subscription-registry` for pubsub cursors

### OCapN Networking - PARTIAL

- [x] OCapN module structure (`xm/ocapn.scm`)
- [x] Sturdyref conversion utilities
- [x] Cap export/import with sturdyref detection
- [ ] CapTP transport integration (blocked by macOS fibers issue)
- [ ] tcp-tls netlayer initialization
- [ ] Remote gatekeeper access via `--remote` flag
- [ ] Tor/Unix socket netlayers

### Event Journal & Store-and-Forward

- [ ] Append-only event log for all mutations
- [ ] Subscription cursors for reliable delivery
- [ ] Outbox for offline mutation queuing
- [ ] `xm sync` replay on reconnect

---

## Summary Statistics

| Category | Total | Complete | In Progress | Not Started |
|----------|-------|----------|-------------|-------------|
| Node Commands | 4 | 4 | 0 | 0 |
| Link Commands | 4 | 4 | 0 | 0 |
| Query Commands | 5 | 5 | 0 | 0 |
| Schema Commands | 3 | 3 | 0 | 0 |
| Graph Commands | 4 | 0 | 0 | 4 |
| Session Commands | 5 | 0 | 0 | 5 |
| Capability Commands | 9 | 9 | 0 | 0 |
| Import/Export | 2 | 0 | 0 | 2 |
| Sync Commands | 2 | 0 | 0 | 2 |
| Daemon Commands | 10 | 7 | 3 | 0 |
| Store Commands | 4 | 0 | 0 | 4 |
| **Total** | **52** | **32** | **3** | **17** |

**Implementation Progress: ~62% complete** (functional commands)

---

## Recommended Next Steps

1. **Fix OCapN netlayer on macOS** - investigate fibers/epoll compatibility
2. **Graph commands** - useful for managing named graphs
3. **Wire session stubs** - make session tracking functional
4. **Import/export** - essential for data portability
5. **Store commands** - backup/restore functionality
