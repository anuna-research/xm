;;; xm/main.scm --- Main entry point for xm CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This is the main entry point for the xm CLI tool.
;;; It handles argument parsing, daemon connection, and command dispatch.

(define-module (xm main)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm cli parser)
  #:use-module (xm cli output)
  #:use-module (xm cli node)
  #:use-module (xm cli link)
  #:use-module (xm cli query)
  #:use-module (xm cli session)
  #:use-module (xm cli cap)
  #:use-module (xm cli schema)
  #:use-module (xm cli graph)
  #:use-module (xm cli store-cmd)
  #:use-module (xm cli io)
  #:use-module (xm cli sync)
  #:use-module (xm cli daemon)
  #:use-module (xm cli keys)
  #:use-module (xm store)
  #:export (main))

;;; --------------------------------------------------------------------
;;; Version and Help
;;; --------------------------------------------------------------------

(define *version* "0.1.0")

(define *help-text* "
xm - Cross Memory: Linked memory for LLM agents

Usage:
  xm [global-options] <command> [command-options]

Commands:
  node       Manage knowledge nodes (create, get, update, delete)
  link       Manage links between nodes
  query      Query the knowledge graph (sparql, nodes, backlinks, path)
  schema     Introspect schema (classes, predicates, describe)
  graph      Manage named graphs (list, create, drop, stats)
  session    Manage agent sessions
  cap        Manage capabilities
  keys       Manage agent identity keys (for OCapN networking)
  import     Import knowledge from files
  export     Export knowledge to files
  subscribe  Subscribe to real-time changes
  sync       Synchronize with remote xm daemon
  daemon     Manage the xm daemon
  store      Store management (compact, backup, restore, info)
  eval       Run evaluations (locomo benchmark)

Global Options:
  -h, --help           Show help for command
  --version            Show version and exit
  -d, --debug          Include debug information
  -q, --quiet          Suppress non-essential output
  -v, --verbose        Show detailed progress
  --json               Output in JSON format
  --no-color           Disable colored output
  --no-input           Disable interactive prompts
  --store PATH         Path to xm store (default: ~/.local/share/xm)
  --session ID         Use existing session
  --cap REF            Capability reference for access control
  --remote URI         Connect to remote xm daemon

Examples:
  # Create a knowledge node
  xm node create -t entity -p name=acme-api -p kind=repository

  # Query with SPARQL
  xm query sparql \"SELECT ?s WHERE { ?s a prov:Entity }\"

  # Find backlinks (Org-roam style)
  xm query backlinks xm:entity/fastapi

  # Start a session
  xm session start -a claude-code -p \"Debug auth bug\"

Documentation: https://xm.dev/docs
")

;;; --------------------------------------------------------------------
;;; Command-Level Help
;;; --------------------------------------------------------------------

(define *command-help*
  '((node . "
xm node - Manage knowledge nodes

Usage:
  xm node <subcommand> [options]

Subcommands:
  create     Create a new node
  get        Retrieve a node with properties and links
  update     Update node properties
  delete     Delete a node

Examples:
  xm node create -t entity -p name=my-api -p kind=service
  xm node get xm:node/abc123
  xm node update xm:node/abc123 -p status=active
  xm node delete xm:node/abc123 --force
")
    (link . "
xm link - Manage links between nodes

Usage:
  xm link <subcommand> [options]

Subcommands:
  create     Create a link between nodes
  get        Retrieve link metadata
  list       List links (filterable)
  delete     Delete a link

Examples:
  xm link create --from xm:node/a --to xm:node/b --predicate skos:related
  xm link list --from xm:node/abc123
")
    (query . "
xm query - Query the knowledge graph

Usage:
  xm query <subcommand> [options]

Subcommands:
  sparql     Execute a SPARQL query
  nodes      Search for nodes by criteria
  backlinks  Find nodes linking TO a target (Org-roam style)
  path       Find paths between nodes

Examples:
  xm query sparql \"SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10\"
  xm query nodes --type entity
  xm query backlinks xm:node/abc123
  xm query path --from xm:node/a --to xm:node/b
")
    (session . "
xm session - Manage agent sessions

Usage:
  xm session <subcommand> [options]

Subcommands:
  start      Start a new session
  end        End an active session
  list       List sessions
  resume     Resume a previous session
  history    View session activity

Examples:
  xm session start -a claude-code -p \"Debug auth bug\"
  xm session list --agent claude-code --since 7d
  xm session end <SESSION_ID> --summary \"Fixed the bug\"
")
    (cap . "
xm cap - Manage capabilities

Usage:
  xm cap <subcommand> [options]

Subcommands:
  create     Create a capability
  attenuate  Create weaker child capability
  revoke     Revoke a capability
  list       List capabilities
  inspect    Show capability details

Examples:
  xm cap create --graphs xm:graph/public --permissions read,write
  xm cap attenuate <CAP_REF> --remove-permission write
")
    (schema . "
xm schema - Introspect schema

Usage:
  xm schema <subcommand> [options]

Subcommands:
  classes    List all classes with instance counts
  predicates List all predicates with usage counts
  describe   Describe a class or predicate

Examples:
  xm schema classes
  xm schema predicates
  xm schema describe prov:Entity
")
    (graph . "
xm graph - Manage named graphs

Usage:
  xm graph <subcommand> [options]

Subcommands:
  list       List all named graphs
  create     Create a new named graph
  drop       Drop a named graph and its triples
  stats      Show detailed graph statistics

Options:
  -v, --verbose    Show triple counts (for list)
  -f, --force      Skip confirmation (for drop)
  -n, --dry-run    Show what would be deleted (for drop)

Examples:
  xm graph list
  xm graph list --verbose
  xm graph create xm:graph/project/acme-api
  xm graph drop xm:graph/project/old-project --force
  xm graph stats xm:graph/public
")
    (store . "
xm store - Store management commands

Usage:
  xm store <subcommand> [options]

Subcommands:
  compact    Compact and optimize the store
  backup     Backup the store to a file
  restore    Restore the store from a backup
  info       Show store information and statistics

Options:
  -o, --output FILE    Output file for backup
  --from FILE          Input file for restore
  --merge              Merge with existing data (restore only)
  -f, --force          Skip confirmation prompt
  --format FORMAT      RDF format: nquads, turtle, ntriples

Examples:
  xm store info
  xm store compact
  xm store backup -o backup.nq
  xm store restore --from backup.nq
  xm store restore --from backup.nq --merge
")
    (import . "
xm import - Import RDF data from files

Usage:
  xm import <file> [options]

Options:
  -g, --graph URI      Target graph (default: xm:graph/public)
  -f, --format FORMAT  Input format: turtle, ntriples, nquads (auto-detect)
  --replace            Replace graph contents instead of merging

Examples:
  xm import data.ttl
  xm import data.nq -g xm:graph/project/myproject
  xm import backup.nt --replace
")
    (export . "
xm export - Export RDF data to files

Usage:
  xm export [options]

Options:
  -g, --graph URI      Source graph (default: all graphs)
  -o, --output FILE    Output file (default: stdout)
  -f, --format FORMAT  Output format: turtle, ntriples, nquads (default: turtle)

Examples:
  xm export                           # Export all to stdout as Turtle
  xm export -o backup.nq -f nquads    # Full backup with graphs
  xm export -g xm:graph/public -o public.ttl
")
    (daemon . "
xm daemon - Manage the xm daemon

Usage:
  xm daemon <subcommand> [options]

Subcommands:
  start      Start the daemon
  stop       Stop the daemon
  restart    Restart the daemon
  status     Show daemon status
  listen     Add an OCapN listener
  listeners  List active OCapN listeners

Options (start):
  --foreground, -F    Run in foreground (don't background)

Options (listen):
  --port, -p PORT     Port number to listen on (required)
  --host, -H HOST     Host/interface to bind to (default: localhost)
  --type TYPE         Listener type: tcp-tls (default: tcp-tls)

Examples:
  xm daemon start
  xm daemon start --foreground
  xm daemon status
  xm daemon stop
  xm daemon restart
  xm daemon listeners
  xm daemon listen --port 9999
")
    (keys . "
xm keys - Manage agent identity keys

Usage:
  xm keys <subcommand> [options]

Subcommands:
  info         Show agent identity (fingerprint, paths)
  generate     Generate new agent keys
  fingerprint  Print just the fingerprint (for scripts)
  path         Show paths to key files
  export       Export keys for backup/migration
  import       Import keys from backup

Options:
  --force      Overwrite existing keys (generate, import)

The agent fingerprint (SHA256 hash of certificate) is used in OCapN
sturdyrefs to identify this agent to remote peers.

Examples:
  xm keys info
  xm keys generate
  xm keys fingerprint
  xm keys export ~/backup/my-agent
  xm keys import ~/backup/my-agent --force
")
    (eval . "
xm eval - Run evaluations and benchmarks

Usage:
  xm eval <benchmark> <subcommand> [options]

Benchmarks:
  locomo     LoCoMo long-term conversational memory benchmark

Subcommands (locomo):
  quick-test  Run a quick sanity test
  run         Run evaluation with a single condition
  compare     Compare multiple conditions
  ingest      Ingest dataset into xm store

Options:
  -c, --condition COND    Retrieval condition (xm-hybrid, xm-sparql, etc.)
  --conditions C1,C2,...  Comma-separated conditions for compare
  --conversation ID       Specific conversation ID
  --category N            QA category (1=single-hop, 2=temporal, 3=commonsense, 4=multi-hop, 5=adversarial)
  -l, --limit N           Max QA pairs per conversation

Examples:
  xm eval locomo quick-test
  xm eval locomo run --condition xm-hybrid --verbose
  xm eval locomo compare --conditions baseline-raw,xm-hybrid
  xm eval locomo run --category 4 --verbose  # multi-hop only
")))

(define (display-command-help command)
  "Display help for a specific command."
  (let ((help-text (assoc-ref *command-help* command)))
    (if help-text
        (display help-text)
        (format #t "No help available for command: ~a\n" command))))

;;; --------------------------------------------------------------------
;;; Store Initialization
;;; --------------------------------------------------------------------

(define (ensure-store-directory path)
  "Ensure the store directory and its parents exist."
  (let ((parent (dirname path)))
    (unless (file-exists? parent)
      (ensure-store-directory parent))
    (unless (file-exists? path)
      (mkdir path))))

;;; --------------------------------------------------------------------
;;; Main Entry Point
;;; --------------------------------------------------------------------

(define (main args)
  "Main entry point for xm CLI."
  (let* ((parsed (parse-args args))
         (global-opts (assoc-ref parsed 'global))
         (command (assoc-ref parsed 'command))
         (subcommand (assoc-ref parsed 'subcommand))
         (opts (assoc-ref parsed 'options))
         (positional (assoc-ref parsed 'positional)))

    ;; Handle --version
    (when (assoc-ref global-opts "version")
      (format #t "xm version ~a\n" *version*)
      (exit 0))

    ;; Handle help requests
    (let ((help-requested (or (assoc-ref global-opts "help")
                              (assoc-ref global-opts "h"))))
      (cond
       ;; No command - show main help
       ((not command)
        (display *help-text*)
        (exit 0))
       ;; Command with --help and no subcommand - show command help
       ((and help-requested command (not subcommand))
        (display-command-help command)
        (exit 0))
       ;; Just --help without command - show main help
       (help-requested
        (display *help-text*)
        (exit 0))))

    ;; Set up environment
    (let ((store-path (or (assoc-ref global-opts "store")
                          (getenv "XM_STORE")
                          (string-append (getenv "HOME") "/.local/share/xm")))
          (cap-ref (or (assoc-ref global-opts "cap")
                       (getenv "XM_CAP")))
          (remote-uri (or (assoc-ref global-opts "remote")
                          (getenv "XM_REMOTE"))))

      ;; Debug output
      (when (or (assoc-ref global-opts "debug")
                (assoc-ref global-opts "d"))
        (format (current-error-port) "Debug: parsed=~a\n" parsed)
        (format (current-error-port) "Debug: command=~a subcommand=~a\n"
                command subcommand)
        (format (current-error-port) "Debug: store=~a cap=~a\n"
                store-path cap-ref))

      ;; Open the store (uses in-memory with file-based persistence)
      (let ((store (begin
                     (when (or (assoc-ref global-opts "debug")
                               (assoc-ref global-opts "d"))
                       (format (current-error-port) "Debug: Opening store at ~a\n" store-path))
                     (make-store store-path))))

        ;; Dispatch to command handler
        (let ((exit-code
               (case command
                 ((node)
                  (handle-node-command subcommand
                                       (acons 'positional positional opts)
                                       global-opts store cap-ref))
                 ((link)
                  (handle-link-command subcommand
                                       (acons 'positional positional opts)
                                       global-opts store cap-ref))
                 ((query)
                  (handle-query-command subcommand
                                        (acons 'positional positional opts)
                                        global-opts store cap-ref))
                 ((session)
                  (handle-session-command subcommand
                                          (acons 'positional positional opts)
                                          global-opts store cap-ref))
                 ((cap)
                  (handle-cap-command subcommand
                                      (acons 'positional positional opts)
                                      global-opts store cap-ref))
                 ((schema)
                  (handle-schema-command subcommand
                                         (acons 'positional positional opts)
                                         global-opts store cap-ref))
                 ((graph)
                  (handle-graph-command subcommand
                                        (acons 'positional positional opts)
                                        global-opts store cap-ref))
                 ((import)
                  (handle-import-command (acons 'positional positional opts)
                                         global-opts store cap-ref))
                 ((export)
                  (handle-export-command (acons 'positional positional opts)
                                         global-opts store cap-ref))
                 ((subscribe)
                  (handle-subscribe-command opts global-opts store cap-ref))
                 ((sync)
                  (handle-sync-command opts global-opts store cap-ref))
                 ((daemon)
                  (handle-daemon-command subcommand opts global-opts))
                 ((keys)
                  (handle-keys-command subcommand
                                       (acons 'positional positional opts)
                                       global-opts))
                 ((store)
                  (handle-store-command subcommand
                                        (acons 'positional positional opts)
                                        global-opts store cap-ref))
                 ((eval)
                  (handle-eval-command subcommand
                                       (acons 'positional positional opts)
                                       global-opts store))
                 (else
                  (output-error "UNKNOWN_COMMAND"
                                (format #f "Unknown command: ~a" command)
                                (format #f "Run 'xm --help' for available commands")
                                global-opts)
                  1))))

          ;; Close store and exit
          (store-close store)
          (exit (or exit-code 0)))))))

;;; --------------------------------------------------------------------
;;; Command Handlers (Placeholders for commands not yet implemented)
;;; --------------------------------------------------------------------

(define (handle-keys-command subcommand opts global-opts)
  "Handle keys subcommands."
  (let ((positional (or (assoc-ref opts 'positional) '())))
    ;; Build args list: subcommand + positional args
    (let ((args (if subcommand
                    (cons (symbol->string subcommand) positional)
                    positional)))
      (keys-command args)
      0)))

(define (handle-daemon-command subcommand opts global-opts)
  "Handle daemon subcommands."
  (catch #t
    (lambda ()
      (case subcommand
        ((start)
         (let* ((foreground (or (assoc-ref opts "foreground")
                                (assoc-ref opts "F")))
                (result (daemon-start #:foreground foreground)))
           (if (assoc-ref global-opts "json")
               (output-result `((ok . #t) (data . ,result)) global-opts)
               (format #t "Daemon started (PID: ~a)\n"
                       (assoc-ref result 'pid)))
           0))
        ((stop)
         (let ((result (daemon-stop)))
           (if (assoc-ref global-opts "json")
               (output-result `((ok . #t) (data . ,result)) global-opts)
               (format #t "Daemon stopped\n"))
           0))
        ((restart)
         (let ((result (daemon-restart)))
           (if (assoc-ref global-opts "json")
               (output-result `((ok . #t) (data . ,result)) global-opts)
               (format #t "Daemon restarted (PID: ~a)\n"
                       (assoc-ref result 'pid)))
           0))
        ((status)
         (let ((result (daemon-status)))
           (if (assoc-ref global-opts "json")
               (output-result `((ok . #t) (data . ,result)) global-opts)
               (if (assoc-ref result 'running)
                   (format #t "Daemon is running (PID: ~a)\n"
                           (assoc-ref result 'pid))
                   (format #t "Daemon is not running\n")))
           0))
        ((listeners)
         ;; List active OCapN listeners
         (if (not (daemon-running?))
             (begin
               (output-error "DAEMON_NOT_RUNNING"
                             "Daemon is not running"
                             "Start daemon with: xm daemon start"
                             global-opts)
               1)
             (let ((result (daemon-rpc "listeners" '())))
               (if (assoc-ref result 'error)
                   (begin
                     (output-error "LISTENERS_ERROR"
                                   (assoc-ref result 'error)
                                   #f global-opts)
                     1)
                   (let ((data (assoc-ref result 'result)))
                     (if (assoc-ref global-opts "json")
                         (output-result `((ok . #t) (data . ,data)) global-opts)
                         (let ((listeners (assoc-ref data 'listeners)))
                           (format #t "\nOCapN Listeners:\n\n")
                           (if (null? listeners)
                               (format #t "  (no listeners active)\n")
                               (for-each
                                (lambda (l)
                                  (format #t "  ~a: ~a:~a (~a) [~a]\n"
                                          (assoc-ref l 'id)
                                          (assoc-ref l 'host)
                                          (assoc-ref l 'port)
                                          (assoc-ref l 'type)
                                          (assoc-ref l 'status)))
                                listeners))
                           (format #t "\nTotal: ~a listener(s)\n" (length listeners))))
                     0)))))
        ((listen)
         ;; Add a new OCapN listener
         (if (not (daemon-running?))
             (begin
               (output-error "DAEMON_NOT_RUNNING"
                             "Daemon is not running"
                             "Start daemon with: xm daemon start"
                             global-opts)
               1)
             (let* ((port-opt (or (assoc-ref opts "port")
                                  (assoc-ref opts "p")))
                    (host-opt (or (assoc-ref opts "host")
                                  (assoc-ref opts "H")
                                  "localhost"))
                    (type-opt (or (assoc-ref opts "type") "tcp-tls")))
               (if (not port-opt)
                   (begin
                     (output-error "MISSING_PORT"
                                   "Port is required"
                                   "Usage: xm daemon listen --port PORT [--host HOST]"
                                   global-opts)
                     2)
                   (let* ((port (string->number port-opt))
                          (result (daemon-rpc "listen"
                                              `(("host" . ,host-opt)
                                                ("port" . ,port)
                                                ("type" . ,type-opt)))))
                     (if (assoc-ref result 'error)
                         (begin
                           (output-error "LISTEN_ERROR"
                                         (assoc-ref result 'error)
                                         #f global-opts)
                           1)
                         (let ((data (assoc-ref result 'result)))
                           (if (assoc-ref global-opts "json")
                               (output-result `((ok . #t) (data . ,data)) global-opts)
                               (format #t "Listener added: ~a:~a (~a)\n"
                                       host-opt port type-opt))
                           0)))))))
        (else
         (output-error "UNKNOWN_SUBCOMMAND"
                       (format #f "Unknown daemon subcommand: ~a" subcommand)
                       "Available: start, stop, restart, status, listen, listeners"
                       global-opts)
         2)))
    (lambda (key . args)
      (output-error "DAEMON_ERROR"
                    (format #f "Daemon error: ~a ~a" key args)
                    #f
                    global-opts)
      1)))

(define (handle-eval-command subcommand opts global-opts store)
  "Handle eval subcommands.
   Subcommand should be 'locomo' for LoCoMo benchmark."
  (let ((positional (or (assoc-ref opts 'positional) '())))
    (case subcommand
      ((locomo)
       ;; Get eval subcommand from positional args
       (let ((eval-subcmd (and (pair? positional) (car positional))))
         (handle-locomo-eval eval-subcmd opts global-opts store)))
      (else
       (output-error "UNKNOWN_BENCHMARK"
                     (format #f "Unknown benchmark: ~a" subcommand)
                     "Available benchmarks: locomo"
                     global-opts)
       2))))

(define (handle-locomo-eval eval-subcmd opts global-opts store)
  "Handle locomo evaluation subcommands."
  (let* ((verbose (or (assoc-ref global-opts "verbose")
                      (assoc-ref global-opts "v")))
         (condition (or (assoc-ref opts "condition")
                        (assoc-ref opts "c")
                        "xm-hybrid"))
         (conditions-str (assoc-ref opts "conditions"))
         (conversation (assoc-ref opts "conversation"))
         (category-str (assoc-ref opts "category"))
         (limit-str (or (assoc-ref opts "limit")
                        (assoc-ref opts "l")))
         ;; Parse options
         (conditions (if conditions-str
                         (map string->symbol (string-split conditions-str #\,))
                         (list (string->symbol condition))))
         (categories (and category-str
                          (filter identity
                                  (map string->number
                                       (string-split category-str #\,)))))
         (qa-limit (and limit-str (string->number limit-str)))
         ;; Data path relative to xm directory
         (data-path "eval/locomo/data/locomo10.json"))

    (case (and eval-subcmd (string->symbol eval-subcmd))
      ((quick-test test)
       (when verbose
         (format #t "Running LoCoMo quick test...~%"))
       (run-locomo-quick-test store data-path verbose global-opts))

      ((run)
       (when verbose
         (format #t "Running LoCoMo evaluation with condition: ~a~%" condition))
       (run-locomo-single store data-path (string->symbol condition)
                          conversation categories qa-limit verbose global-opts))

      ((compare)
       (when verbose
         (format #t "Comparing conditions: ~a~%" conditions))
       (run-locomo-compare store data-path conditions
                           conversation categories qa-limit verbose global-opts))

      ((ingest)
       (when verbose
         (format #t "Ingesting LoCoMo dataset...~%"))
       (run-locomo-ingest store data-path conversation verbose global-opts))

      (else
       (output-error "UNKNOWN_EVAL_SUBCOMMAND"
                     (format #f "Unknown eval subcommand: ~a" eval-subcmd)
                     "Available: quick-test, run, compare, ingest"
                     global-opts)
       2))))

;;; --------------------------------------------------------------------
;;; LoCoMo Evaluation Runners (simplified inline versions)
;;; --------------------------------------------------------------------

(define (run-locomo-quick-test store data-path verbose global-opts)
  "Run a quick LoCoMo sanity test."
  (output-result
   `((message . "LoCoMo quick-test")
     (status . "To run the full evaluation, use:")
     (command . "guile -L guile -L eval/locomo -e '(eval locomo runner)' -c '(use-modules (eval locomo runner)) (display (run-quick-test))'")
     (note . "Full evaluation requires loading eval modules from eval/locomo/"))
   global-opts)
  0)

(define (run-locomo-single store data-path condition conv-id categories qa-limit verbose global-opts)
  "Run LoCoMo evaluation with a single condition."
  (output-result
   `((message . "LoCoMo run")
     (condition . ,(symbol->string condition))
     (status . "To run evaluation, use the runner module:")
     (command . ,(format #f "guile -L guile -L eval/locomo -e '(eval locomo runner)' -c \"(use-modules (eval locomo runner)) (display (run-evaluate #:condition '~a #:verbose ~a))\"" condition verbose)))
   global-opts)
  0)

(define (run-locomo-compare store data-path conditions conv-id categories qa-limit verbose global-opts)
  "Compare multiple LoCoMo conditions."
  (output-result
   `((message . "LoCoMo compare")
     (conditions . ,(map symbol->string conditions))
     (status . "To run comparison, use the runner module:")
     (command . ,(format #f "guile -L guile -L eval/locomo -e '(eval locomo runner)' -c \"(use-modules (eval locomo runner)) (display (run-compare #:conditions '~a))\"" conditions)))
   global-opts)
  0)

(define (run-locomo-ingest store data-path conv-id verbose global-opts)
  "Ingest LoCoMo dataset."
  (output-result
   `((message . "LoCoMo ingest")
     (status . "To ingest dataset, use the runner module:")
     (command . "guile -L guile -L eval/locomo -e '(eval locomo runner)' -c \"(use-modules (eval locomo runner)) (display (run-ingest #:verbose #t))\""))
   global-opts)
  0)
