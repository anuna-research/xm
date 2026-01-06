;;; xm/main.scm --- Main entry point for xm CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
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
  session    Manage agent sessions
  cap        Manage capabilities
  import     Import knowledge from files
  export     Export knowledge to files
  subscribe  Subscribe to real-time changes
  sync       Synchronize with remote xm daemon
  daemon     Manage the xm daemon
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
                 ((import)
                  (handle-import-command opts global-opts store cap-ref))
                 ((export)
                  (handle-export-command opts global-opts store cap-ref))
                 ((subscribe)
                  (handle-subscribe-command opts global-opts store cap-ref))
                 ((sync)
                  (handle-sync-command opts global-opts store cap-ref))
                 ((daemon)
                  (handle-daemon-command subcommand opts global-opts))
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

(define (handle-import-command opts global-opts gatekeeper cap-ref)
  "Handle import command."
  (output-result '((message . "import - not yet implemented")) global-opts)
  0)

(define (handle-export-command opts global-opts gatekeeper cap-ref)
  "Handle export command."
  (output-result '((message . "export - not yet implemented")) global-opts)
  0)

(define (handle-subscribe-command opts global-opts gatekeeper cap-ref)
  "Handle subscribe command."
  (output-result '((message . "subscribe - not yet implemented")) global-opts)
  0)

(define (handle-sync-command opts global-opts gatekeeper cap-ref)
  "Handle sync command."
  (output-result '((message . "sync - not yet implemented")) global-opts)
  0)

(define (handle-daemon-command subcommand opts global-opts)
  "Handle daemon subcommands."
  (case subcommand
    ((start)
     (output-result '((message . "daemon start - not yet implemented")) global-opts))
    ((stop)
     (output-result '((message . "daemon stop - not yet implemented")) global-opts))
    ((restart)
     (output-result '((message . "daemon restart - not yet implemented")) global-opts))
    ((status)
     (output-result '((status . "not running")
                      (message . "daemon status - not yet implemented"))
                    global-opts))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown daemon subcommand: ~a" subcommand)
                   "Available: start, stop, restart, status"
                   global-opts)
     2))
  0)

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
