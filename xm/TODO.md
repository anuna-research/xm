# xm Implementation Status vs SPEC-029

## Summary

**Implementation Progress: 100% complete** (53/53 CLI commands functional)

| Category | Total | Complete | In Progress |
|----------|-------|----------|-------------|
| Node Commands | 4 | 4 | 0 |
| Link Commands | 4 | 4 | 0 |
| Query Commands | 5 | 5 | 0 |
| Schema Commands | 3 | 3 | 0 |
| Graph Commands | 4 | 4 | 0 |
| Session Commands | 6 | 6 | 0 |
| Capability Commands | 9 | 9 | 0 |
| Import/Export | 2 | 2 | 0 |
| Sync Commands | 2 | 2 | 0 |
| Daemon Commands | 10 | 10 | 0 |
| Store Commands | 4 | 4 | 0 |
| **Total** | **53** | **53** | **0** |

---

## Completed Phases

### Phase 1: Storage Layer - COMPLETE

- [x] Oxigraph FFI crate (`oxigraph-ffi/src/lib.rs`)
- [x] Guile FFI bindings (`guile/xm/store.scm`)
- [x] SPARQL query/update support
- [x] N-Quads persistence (file-based workaround for RocksDB ARM64 crash)
- [x] Named graph support (quad model)

### Phase 2: CLI Foundation - COMPLETE

- [x] Argument parser (`guile/xm/cli/parser.scm`)
- [x] JSON/human output formatting (`guile/xm/cli/output.scm`)
- [x] Vocabulary/namespace handling (`guile/xm/vocabulary.scm`)
- [x] Main entry point (`guile/xm/main.scm`)
- [x] Makefile with build/test/install

### Phase 3: Node Commands - COMPLETE

- [x] `xm node create` - create nodes with type/properties
- [x] `xm node get` - retrieve node with properties
- [x] `xm node update` - update node properties
- [x] `xm node delete` - delete nodes

### Phase 4: Link Commands - COMPLETE

- [x] `xm link create` - create typed links with metadata
- [x] `xm link get` - retrieve link details
- [x] `xm link list` - list/filter links
- [x] `xm link delete` - delete links

### Phase 5: Query Commands - COMPLETE

- [x] `xm query sparql` - raw SPARQL queries
- [x] `xm query nodes` - search nodes by criteria
- [x] `xm query backlinks` - Org-roam style backlinks
- [x] `xm query path` - path finding (basic)

### Phase 6: Schema Commands - COMPLETE

- [x] `xm schema classes` - list known node types
- [x] `xm schema predicates` - list predicates with usage stats
- [x] `xm schema describe` - show schema info for a class/predicate

### Phase 7: Graph Commands - COMPLETE

- [x] `xm graph list` - list named graphs with stats
- [x] `xm graph create` - create new named graph
- [x] `xm graph drop` - delete named graph
- [x] `xm graph stats` - detailed graph statistics

### Phase 8: Import/Export Commands - COMPLETE

- [x] `xm import` - import from Turtle/N-Triples/N-Quads files
- [x] `xm export` - export to RDF formats with graph selection

### Phase 9: Session Commands - COMPLETE

- [x] `session start` - create session nodes in RDF store
- [x] `session end` - record session end and summary
- [x] `session list` - query sessions from store
- [x] `session resume` - reload session context
- [x] `session history` - show session discoveries and links
- [x] Automatic session linking via `prov:wasGeneratedBy` (--session flag)

### Phase 10: Capability Commands - COMPLETE

- [x] `cap create` - store capability with graphs/permissions in RDF store
- [x] `cap attenuate` - create child capability with subset validation
- [x] `cap revoke` - revoke capability (marks as revoked in store)
- [x] `cap list` - query capabilities from store
- [x] `cap inspect` - show full capability details
- [x] `cap export` - export as local token or OCapN sturdyref
- [x] `cap import` - import from token or sturdyref
- [x] Capability-enforced queries (`--cap` flag on `xm query sparql`)
- [x] Query rewriting with FROM clause scoping for allowed graphs

### Phase 11: Daemon Commands - COMPLETE

- [x] Daemon process with PID management
- [x] Unix socket IPC for CLI->daemon JSON-RPC communication
- [x] `daemon start` - spawn Goblins vat
- [x] `daemon stop` - graceful shutdown
- [x] `daemon restart` - stop+start
- [x] `daemon status` - show running state
- [x] `daemon listen` - add OCapN listener
- [x] `daemon listeners` - list active listeners
- [x] Goblins runtime initialization with ^cap-registry actor
- [x] OCapN tcp-tls netlayer (with macOS patches)

### Phase 12: Synchronization Commands - COMPLETE

- [x] `xm subscribe` - polling-based change notifications (NDJSON stream)
- [x] `xm sync` - OCapN-based graph synchronization via daemon

### Phase 13: Store Commands - COMPLETE

- [x] `xm store compact` - persist and optimize storage
- [x] `xm store backup` - backup store to file (N-Quads/Turtle/N-Triples)
- [x] `xm store restore` - restore from backup with merge option
- [x] `xm store info` - storage statistics with top classes/predicates

---

## Architecture Components

### Goblins Integration - COMPLETE

- [x] Spritely Goblins 0.16.1 actor model (via Homebrew)
- [x] `^cap-registry` actor for capability label->actor mapping
- [x] `^graph-gatekeeper` actor for SPARQL query rewriting
- [x] `^graph-facet` capability wrapper with access control
- [x] `^session-actor` for session lifecycle
- [x] `^session-registry` for session lookup
- [x] `^capability-registry` for named capability storage
- [x] Runtime vat initialization in daemon
- [x] `^event-journal` for append-only mutation log (spawned in daemon)
- [x] `^subscription-registry` for pubsub cursors (spawned in daemon)
- [x] CLI-to-actor wiring via daemon RPC (query, insert, delete)

### OCapN Networking

- [x] OCapN module structure (`xm/ocapn.scm`)
- [x] Sturdyref conversion utilities
- [x] Cap export/import with sturdyref detection
- [x] OCapN sturdyref enliven (parsing and importing remote capabilities)
- [x] CapTP transport integration (fibers 1.4.0 works on macOS)
- [x] UDS netlayer (`xm/ocapn/netlayer-uds.scm`)
- [x] tcp-tls netlayer (patched for macOS - run `make patch-goblins`)
- [x] mycapn actor for capability registration
- [x] Remote gatekeeper access via `--remote` flag
- [ ] Tor netlayer

---

## Remaining Work

### 1. Tor Netlayer
- OCapN supports Tor onion services but not yet implemented
- Future: Add `^onion-netlayer` for anonymous networking

---

## Notes

### macOS tcp-tls Patch
The Goblins tcp-tls netlayer requires a patch on macOS:
- Upstream bug: Goblins passes `O_NONBLOCK` to `accept()` which fails on macOS
- macOS lacks `accept4()` syscall
- Fix: `patches/goblins-tcp-tls-macos.patch`
- Apply with: `make patch-goblins` (requires sudo)
- Check status: `make check-patches`
