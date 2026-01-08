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

### Phase 7: Graph Commands - COMPLETE

Per SPEC-029 Section 5.15:

- [x] `xm graph list` - list named graphs with stats
- [x] `xm graph create` - create new named graph
- [x] `xm graph drop` - delete named graph
- [x] `xm graph stats` - detailed graph statistics

### Phase 8: Import/Export Commands - COMPLETE

Per SPEC-029 Section 5.18:

- [x] `xm import` - import from Turtle/N-Triples/N-Quads files
- [x] `xm export` - export to RDF formats with graph selection

### Phase 9: Session Commands - COMPLETE

Per SPEC-029 Section 5.16:

- [x] `session start` - create session nodes in RDF store
- [x] `session end` - record session end and summary
- [x] `session list` - query sessions from store
- [x] `session resume` - reload session context
- [x] `session history` - show session discoveries and links
- [x] Automatic session linking (discoveries -> session) via `prov:wasGeneratedBy`

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

### Phase 11: Daemon Commands - COMPLETE

Per SPEC-029 Section 5.20:

- [x] Implement daemon process with PID management
- [x] Unix socket IPC for CLI->daemon JSON-RPC communication
- [x] `daemon start` - spawn Goblins vat (foreground mode works)
- [x] `daemon stop` - graceful shutdown
- [x] `daemon restart` - stop+start
- [x] `daemon status` - show running state
- [x] Goblins runtime initialization with ^cap-registry actor
- [x] OCapN UDS netlayer (Unix Domain Socket - macOS compatible)
- [x] `daemon listen` - add OCapN listener
- [x] `daemon listeners` - list active listeners

### Phase 12: Synchronization Commands - PARTIAL

Per SPEC-029 Section 5.19:

- [x] `xm subscribe` - polling-based change notifications (NDJSON stream)
- [~] `xm sync` - CLI implemented but requires OCapN daemon for remote sync

### Phase 13: Store Commands - COMPLETE

Per SPEC-029 Section 5.21:

- [x] `xm store compact` - persist and optimize storage
- [x] `xm store backup` - backup store to file (N-Quads/Turtle/N-Triples)
- [x] `xm store restore` - restore from backup with merge option
- [x] `xm store info` - storage statistics with top classes/predicates

---

## Architecture Components

### Goblins Integration - IN PROGRESS

- [x] Integrate Spritely Goblins 0.16.1 actor model (via Homebrew)
- [x] `^cap-registry` actor for capability label->actor mapping
- [x] Runtime vat initialization in daemon
- [x] `^graph-gatekeeper` actor for SPARQL query rewriting (gatekeeper.scm)
- [x] `^graph-facet` capability wrapper with access control (capability.scm)
- [x] `^session-actor` for session lifecycle (session.scm)
- [x] `^session-registry` for session lookup (session.scm)
- [x] `^capability-registry` for named capability storage (capability.scm)
- [ ] Wire Goblins actors to CLI commands (currently using direct store access)
- [ ] `^event-journal` for append-only mutation log
- [ ] `^subscription-registry` for pubsub cursors

### OCapN Networking - FUNCTIONAL

- [x] OCapN module structure (`xm/ocapn.scm`)
- [x] Sturdyref conversion utilities
- [x] Cap export/import with sturdyref detection
- [x] CapTP transport integration (fibers 1.4.0 works on macOS)
- [x] UDS netlayer (`xm/ocapn/netlayer-uds.scm` - macOS compatible)
- [x] mycapn actor for capability registration with UDS networking
- [x] tcp-tls netlayer (patched - run `make patch-goblins` to apply)
      - Upstream bug: Goblins passes `O_NONBLOCK` to `accept()` which fails on macOS
      - macOS lacks `accept4()` syscall, only supports `accept()` without flags
      - Fix: `patches/goblins-tcp-tls-macos.patch` and `patches/goblins-testuds-macos.patch`
      - Apply with: `make patch-goblins` (requires sudo)
      - Check status: `make check-patches`
      - TODO: Submit upstream patch to Goblins
- [x] **OCapN sturdyref enliven** - parsing and importing remote capabilities
- [ ] Remote gatekeeper access via `--remote` flag
- [ ] Tor netlayer

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
| Graph Commands | 4 | 4 | 0 | 0 |
| Session Commands | 6 | 6 | 0 | 0 |
| Capability Commands | 9 | 9 | 0 | 0 |
| Import/Export | 2 | 2 | 0 | 0 |
| Sync Commands | 2 | 1 | 1 | 0 |
| Daemon Commands | 10 | 10 | 0 | 0 |
| Store Commands | 4 | 4 | 0 | 0 |
| **Total** | **53** | **52** | **1** | **0** |

**Implementation Progress: ~98% complete** (functional CLI commands)

---

## Remaining Stubbed Features

The following features have stub implementations or are not fully wired:

1. **Remote Sync**
   - `xm sync` CLI exists but requires OCapN daemon for actual sync
   - Needs: Implement actual OCapN-based graph synchronization protocol

2. **Goblins Actor Wiring**
   - Actors exist (`^graph-gatekeeper`, `^session-actor`, etc.)
   - CLI commands use direct store access instead of actor method calls
   - Needs: Route CLI commands through daemon actors for capability enforcement

3. **Event Journal**
   - Not implemented
   - Needs: Append-only event log for all mutations, subscription cursors

4. **Remote Gatekeeper Access**
   - `--remote` flag mentioned but not implemented
   - Needs: Connect to remote xm daemon for queries

---

## Recommended Next Steps

1. ~~**Fix OCapN netlayer on macOS**~~ - RESOLVED: fibers 1.4.0 from Homebrew tap works
2. ~~**OCapN sturdyref enliven**~~ - RESOLVED: implemented in daemon-cap-import
3. ~~**Daemon listeners**~~ - RESOLVED: daemon listen/listeners commands implemented
4. ~~**Automatic session linking**~~ - RESOLVED: node/link create now adds prov:wasGeneratedBy
5. **Wire Goblins actors** - route CLI through daemon actors for proper capability enforcement
6. **Remote gatekeeper access** - implement `--remote` flag for cross-daemon queries
7. **Event journal** - enable reliable pub/sub and offline sync
