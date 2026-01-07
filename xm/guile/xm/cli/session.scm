;;; xm/cli/session.scm --- Session commands for CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Implements session start/end/list/resume/history commands per SPEC-029 Section 5.14.
;;; Sessions group related interactions and automatically link discoveries.

(define-module (xm cli session)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-session-command
            cmd-session-start
            cmd-session-end
            cmd-session-list
            cmd-session-resume
            cmd-session-history))

;;; --------------------------------------------------------------------
;;; Session Graph and URI Helpers
;;; --------------------------------------------------------------------

(define (session-graph-uri)
  "Get the graph URI for storing sessions."
  (xm-graph-uri "sessions"))

(define (xm-uri local-name)
  "Create a full URI in the xm namespace."
  (string-append xm-ns local-name))

;;; --------------------------------------------------------------------
;;; Session Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-session-command subcommand opts global-opts store cap-ref)
  "Dispatch session subcommands."
  (case subcommand
    ((start) (cmd-session-start opts global-opts store cap-ref))
    ((end) (cmd-session-end opts global-opts store cap-ref))
    ((list) (cmd-session-list opts global-opts store cap-ref))
    ((resume) (cmd-session-resume opts global-opts store cap-ref))
    ((history) (cmd-session-history opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown session subcommand: ~a" subcommand)
                   "Available: start, end, list, resume, history"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; session start
;;; --------------------------------------------------------------------

(define (cmd-session-start opts global-opts store cap-ref)
  "Start a new agent session.
   Options:
   -a, --agent AGENT_ID: Agent identifier (required)
   -p, --purpose TEXT: Session purpose/description
   -c, --context NODE_ID: Initial context nodes (repeatable)
   --parent SESSION_ID: Parent session for continuations"

  (let* ((agent-id (or (assoc-ref opts "agent")
                       (assoc-ref opts "a")))
         (purpose (or (assoc-ref opts "purpose")
                      (assoc-ref opts "p")))
         (context-nodes (filter-map
                         (lambda (opt)
                           (and (member (car opt) '("context" "c"))
                                (cdr opt)))
                         opts))
         (parent-id (assoc-ref opts "parent"))
         (graph-uri (session-graph-uri)))

    ;; Validate required options
    (unless agent-id
      (output-error "MISSING_AGENT"
                    "Agent identifier is required"
                    "Use -a or --agent to specify the agent ID"
                    global-opts)
      (exit 2))

    ;; Create session and persist to store
    (let* ((session-id (xm-session-uri (generate-uuid)))
           (timestamp (current-iso-timestamp)))

      ;; Store session as RDF triples
      (store-insert-quad store session-id rdf:type prov:Activity #:graph graph-uri)
      (store-insert-quad store session-id dcterms:created timestamp #:graph graph-uri)
      (store-insert-quad store session-id (xm-uri "agent") agent-id #:graph graph-uri)
      (store-insert-quad store session-id (xm-uri "active") "true" #:graph graph-uri)
      (when purpose
        (store-insert-quad store session-id (xm-uri "purpose") purpose #:graph graph-uri))
      (when parent-id
        (store-insert-quad store session-id (xm-uri "parent") (expand-uri parent-id) #:graph graph-uri))

      ;; Link context nodes
      (for-each
       (lambda (ctx)
         (store-insert-quad store session-id (xm-uri "context") (expand-uri ctx) #:graph graph-uri))
       context-nodes)

      (let ((result `((session_id . ,session-id)
                      (agent . ,agent-id)
                      (purpose . ,(or purpose ""))
                      (started_at . ,timestamp)
                      (context_nodes . ,context-nodes)
                      (parent . ,parent-id))))

        (if (assoc-ref global-opts "json")
            (output-result result global-opts)
            (begin
              (format #t "\nSession started: ~a\n" session-id)
              (format #t "Agent: ~a\n" agent-id)
              (when purpose (format #t "Purpose: ~a\n" purpose))
              (format #t "Started: ~a\n" timestamp)
              (format #t "\nExport SESSION_ID=~a\n" session-id)))))))

;;; --------------------------------------------------------------------
;;; session end
;;; --------------------------------------------------------------------

(define (cmd-session-end opts global-opts store cap-ref)
  "End an active session.
   Usage: xm session end <SESSION_ID>
   Options:
   -s, --summary TEXT: Session summary"

  (let* ((positional (assoc-ref opts 'positional))
         ;; Check positional args first, then fall back to global --session option
         (session-id (or (and (pair? positional) (car positional))
                         (assoc-ref global-opts "session")))
         (summary (or (assoc-ref opts "summary")
                      (assoc-ref opts "s")))
         (graph-uri (session-graph-uri)))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session end <SESSION_ID> or xm --session <ID> session end"
                    global-opts)
      (exit 2))

    ;; Expand URI if prefixed
    (let* ((full-session-id (expand-uri session-id))
           (timestamp (current-iso-timestamp)))

      ;; First check if session exists and is active
      (let* ((check-sparql (format #f "SELECT ?active FROM <~a> WHERE { <~a> <~a> ?active }"
                                    graph-uri full-session-id (xm-uri "active")))
             (check-result (catch #t
                             (lambda () (store-query store check-sparql))
                             (lambda (key . args)
                               "{\"head\":{\"vars\":[]},\"results\":{\"bindings\":[]}}")))
             (check-parsed (json-string->scm check-result))
             (check-bindings (get-sparql-bindings check-parsed))
             (current-active (and (pair? check-bindings)
                                  (get-binding-value (car check-bindings) "active"))))

        (cond
         ;; Session doesn't exist (no active value found)
         ((not current-active)
          (output-error "SESSION_NOT_FOUND"
                        (format #f "Session not found: ~a" session-id)
                        "The specified session does not exist"
                        global-opts)
          (exit 1))

         ;; Session already ended
         ((equal? current-active "false")
          (output-error "SESSION_ALREADY_ENDED"
                        (format #f "Session already ended: ~a" session-id)
                        "This session has already been ended"
                        global-opts)
          (exit 1))

         ;; Session is active - end it
         (else
          ;; Delete old active value to avoid duplicates
          (let ((delete-sparql (format #f "DELETE DATA { GRAPH <~a> { <~a> <~a> \"true\" } }"
                                        graph-uri full-session-id (xm-uri "active"))))
            (catch #t
              (lambda () (store-update store delete-sparql))
              (lambda (key . args)
                ;; Ignore errors from delete - might not exist
                #f)))

          ;; Insert new active=false value
          (store-insert-quad store full-session-id (xm-uri "active") "false" #:graph graph-uri)
          (store-insert-quad store full-session-id (xm-uri "endedAt") timestamp #:graph graph-uri)
          (when summary
            (store-insert-quad store full-session-id (xm-uri "summary") summary #:graph graph-uri))

          (let ((result `((session_id . ,full-session-id)
                          (ended_at . ,timestamp)
                          (summary . ,summary))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                (begin
                  (format #t "\nSession ended: ~a\n" (compact-uri full-session-id))
                  (format #t "Ended at: ~a\n" timestamp)
                  (when summary (format #t "Summary: ~a\n" summary)))))))))))

;;; --------------------------------------------------------------------
;;; session list
;;; --------------------------------------------------------------------

(define (cmd-session-list opts global-opts store cap-ref)
  "List sessions.
   Options:
   -a, --agent AGENT_ID: Filter by agent
   --since TIME: Filter by start time
   --active-only: Only show active sessions
   --limit N: Maximum results (default: 20)"

  (let* ((agent-filter (or (assoc-ref opts "agent")
                           (assoc-ref opts "a")))
         (since-time (assoc-ref opts "since"))
         (active-only (assoc-ref opts "active-only"))
         (limit (or (assoc-ref opts "limit") "20"))
         (graph-uri (session-graph-uri)))

    ;; Build SPARQL query to find sessions
    (let* ((sparql (build-session-list-query agent-filter active-only limit graph-uri))
           (json-result (catch #t
                          (lambda () (store-query store sparql))
                          (lambda (key . args)
                            "{\"head\":{\"vars\":[]},\"results\":{\"bindings\":[]}}")))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (sessions (map parse-session-binding bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((sessions . ,sessions)
                           (count . ,(length sessions))
                           (filters . ((agent . ,agent-filter)
                                       (since . ,since-time)
                                       (active_only . ,(if active-only #t #f)))))
                         global-opts)
          (begin
            (format #t "\nSessions")
            (when agent-filter (format #t " for ~a" agent-filter))
            (when active-only (format #t " (active only)"))
            (format #t ":\n\n")
            (if (null? sessions)
                (format #t "  (no sessions found)\n")
                (for-each
                 (lambda (sess)
                   (format #t "  ~a  ~a  ~a  ~a\n"
                           (compact-uri (assoc-ref sess 'session_id))
                           (or (assoc-ref sess 'agent) "unknown")
                           (or (assoc-ref sess 'started_at) "")
                           (if (equal? (assoc-ref sess 'active) "true") "active" "ended")))
                 sessions)))))))

(define (build-session-list-query agent-filter active-only limit graph-uri)
  "Build SPARQL query to list sessions.
   Uses subquery to get the latest active status for each session to avoid duplicates."
  (string-append
   "SELECT DISTINCT ?session ?agent ?started ?active ?purpose\n"
   (format #f "FROM <~a>\n" graph-uri)
   "WHERE {\n"
   "  ?session a <" prov:Activity "> .\n"
   "  ?session <" (xm-uri "agent") "> ?agent .\n"
   "  OPTIONAL { ?session <" dcterms:created "> ?started }\n"
   ;; For active status, prefer 'false' (ended) over 'true' (active) if both exist
   "  OPTIONAL {\n"
   "    ?session <" (xm-uri "active") "> ?active .\n"
   "    FILTER NOT EXISTS {\n"
   "      ?session <" (xm-uri "active") "> ?other_active .\n"
   "      FILTER(?active = \"true\" && ?other_active = \"false\")\n"
   "    }\n"
   "  }\n"
   "  OPTIONAL { ?session <" (xm-uri "purpose") "> ?purpose }\n"
   (if agent-filter
       (format #f "  FILTER(?agent = \"~a\")\n" agent-filter)
       "")
   (if active-only
       "  FILTER(?active = \"true\")\n"
       "")
   "}\n"
   "ORDER BY DESC(?started)\n"
   (format #f "LIMIT ~a" limit)))

(define (parse-session-binding binding)
  "Parse a SPARQL binding into a session alist."
  `((session_id . ,(get-binding-value binding "session"))
    (agent . ,(get-binding-value binding "agent"))
    (started_at . ,(get-binding-value binding "started"))
    (active . ,(get-binding-value binding "active"))
    (purpose . ,(get-binding-value binding "purpose"))))

(define (get-binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-obj (assoc-ref binding var-name)))
    (and var-obj (assoc-ref var-obj "value"))))

(define (get-sparql-bindings json-obj)
  "Extract bindings from SPARQL JSON results."
  (let ((results (assoc-ref json-obj "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

;;; --------------------------------------------------------------------
;;; session resume
;;; --------------------------------------------------------------------

(define (cmd-session-resume opts global-opts store cap-ref)
  "Resume a previous session.
   Usage: xm session resume <SESSION_ID>
   Options:
   --replay: Replay session discoveries as context"

  (let* ((positional (assoc-ref opts 'positional))
         (session-id (and (pair? positional) (car positional)))
         (replay (assoc-ref opts "replay"))
         (graph-uri (session-graph-uri)))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session resume <SESSION_ID>"
                    global-opts)
      (exit 2))

    (let ((full-session-id (expand-uri session-id)))

      ;; Query session details from store
      (let* ((session-sparql (format #f "SELECT ?agent ?active ?purpose
FROM <~a>
WHERE {
  <~a> a <~a> .
  <~a> <~a> ?agent .
  OPTIONAL { <~a> <~a> ?active }
  OPTIONAL { <~a> <~a> ?purpose }
}" graph-uri full-session-id prov:Activity
   full-session-id (xm-uri "agent")
   full-session-id (xm-uri "active")
   full-session-id (xm-uri "purpose")))
             (session-result (store-query store session-sparql))
             (session-parsed (json-string->scm session-result))
             (session-bindings (get-sparql-bindings session-parsed)))

        (when (null? session-bindings)
          (output-error "SESSION_NOT_FOUND"
                        (format #f "Session not found: ~a" session-id)
                        "Use 'xm session list' to see available sessions"
                        global-opts)
          (exit 1))

        (let* ((session-info (car session-bindings))
               (agent (get-binding-value session-info "agent"))
               (was-active (get-binding-value session-info "active"))
               ;; Query context nodes
               (context-sparql (format #f "SELECT ?ctx FROM <~a> WHERE { <~a> <~a> ?ctx }"
                                        graph-uri full-session-id (xm-uri "context")))
               (context-result (store-query store context-sparql))
               (context-parsed (json-string->scm context-result))
               (context-bindings (get-sparql-bindings context-parsed))
               (context-nodes (map (lambda (b) (compact-uri (get-binding-value b "ctx"))) context-bindings))
               ;; Query discoveries (nodes generated by session)
               (disco-sparql (format #f "SELECT ?node FROM <~a> WHERE { ?node <~a> <~a> }"
                                      (xm-graph-uri "public") prov:wasGeneratedBy full-session-id))
               (disco-result (catch #t
                              (lambda () (store-query store disco-sparql))
                              (lambda args "{\"results\":{\"bindings\":[]}}")))
               (disco-parsed (json-string->scm disco-result))
               (disco-bindings (get-sparql-bindings disco-parsed))
               (discoveries (map (lambda (b) (compact-uri (get-binding-value b "node"))) disco-bindings))
               (timestamp (current-iso-timestamp)))

          ;; If session was ended, reactivate it
          (when (equal? was-active "false")
            ;; Delete the old active=false
            (let ((delete-sparql (format #f "DELETE DATA { GRAPH <~a> { <~a> <~a> \"false\" } }"
                                          graph-uri full-session-id (xm-uri "active"))))
              (catch #t (lambda () (store-update store delete-sparql)) (lambda args #f)))
            ;; Insert active=true
            (store-insert-quad store full-session-id (xm-uri "active") "true" #:graph graph-uri)
            (store-insert-quad store full-session-id (xm-uri "resumedAt") timestamp #:graph graph-uri))

          (let ((result `((session_id . ,(compact-uri full-session-id))
                          (resumed_at . ,timestamp)
                          (original_agent . ,agent)
                          (context_nodes . ,(length context-nodes))
                          (discoveries . ,(length discoveries))
                          (replay . ,(if replay #t #f)))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                (begin
                  (format #t "\nSession resumed: ~a\n" (compact-uri full-session-id))
                  (format #t "Agent: ~a\n" agent)
                  (format #t "Context nodes: ~a\n" (length context-nodes))
                  (format #t "Previous discoveries: ~a\n" (length discoveries))
                  (when replay (format #t "Replaying discoveries into context\n"))))))))))

;;; --------------------------------------------------------------------
;;; session history
;;; --------------------------------------------------------------------

(define (cmd-session-history opts global-opts store cap-ref)
  "Show session history (discoveries and context).
   Usage: xm session history <SESSION_ID>
   Options:
   --limit N: Maximum items (default: 100)"

  (let* ((positional (assoc-ref opts 'positional))
         (session-id (and (pair? positional) (car positional)))
         (limit (or (assoc-ref opts "limit") "100"))
         (graph-uri (session-graph-uri)))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session history <SESSION_ID>"
                    global-opts)
      (exit 2))

    (let ((full-session-id (expand-uri session-id)))

      ;; First verify the session exists
      (let* ((check-sparql (format #f "SELECT ?agent FROM <~a> WHERE { <~a> a <~a>; <~a> ?agent }"
                                    graph-uri full-session-id prov:Activity (xm-uri "agent")))
             (check-result (store-query store check-sparql))
             (check-parsed (json-string->scm check-result))
             (check-bindings (get-sparql-bindings check-parsed)))

        (when (null? check-bindings)
          (output-error "SESSION_NOT_FOUND"
                        (format #f "Session not found: ~a" session-id)
                        "Use 'xm session list' to see available sessions"
                        global-opts)
          (exit 1))

        ;; Query context nodes
        (let* ((context-sparql (format #f "SELECT ?ctx FROM <~a> WHERE { <~a> <~a> ?ctx } LIMIT ~a"
                                        graph-uri full-session-id (xm-uri "context") limit))
               (context-result (store-query store context-sparql))
               (context-parsed (json-string->scm context-result))
               (context-bindings (get-sparql-bindings context-parsed))
               (context-nodes (map (lambda (b) (compact-uri (get-binding-value b "ctx"))) context-bindings))
               ;; Query discoveries (nodes generated during session) from public graph
               (disco-sparql (format #f "SELECT ?node ?type ?created
FROM <~a>
WHERE {
  ?node <~a> <~a> .
  OPTIONAL { ?node a ?type }
  OPTIONAL { ?node <~a> ?created }
}
ORDER BY DESC(?created)
LIMIT ~a" (xm-graph-uri "public") prov:wasGeneratedBy full-session-id dcterms:created limit))
               (disco-result (catch #t
                              (lambda () (store-query store disco-sparql))
                              (lambda args "{\"results\":{\"bindings\":[]}}")))
               (disco-parsed (json-string->scm disco-result))
               (disco-bindings (get-sparql-bindings disco-parsed))
               (discoveries (map (lambda (b)
                                   `((id . ,(compact-uri (get-binding-value b "node")))
                                     (type . ,(let ((t (get-binding-value b "type")))
                                                (if t (compact-uri t) #f)))
                                     (created . ,(get-binding-value b "created"))))
                                 disco-bindings))
               ;; Query links created during session
               (link-sparql (format #f "SELECT ?link ?source ?target ?created
FROM <~a>
WHERE {
  ?link <~a> <~a> .
  ?link <~a> ?source .
  ?link <~a> ?target .
  OPTIONAL { ?link <~a> ?created }
}
ORDER BY DESC(?created)
LIMIT ~a" (xm-graph-uri "public") prov:wasGeneratedBy full-session-id
   (xm-uri "source") (xm-uri "target") dcterms:created limit))
               (link-result (catch #t
                             (lambda () (store-query store link-sparql))
                             (lambda args "{\"results\":{\"bindings\":[]}}")))
               (link-parsed (json-string->scm link-result))
               (link-bindings (get-sparql-bindings link-parsed))
               (links (map (lambda (b)
                             `((id . ,(compact-uri (get-binding-value b "link")))
                               (source . ,(compact-uri (get-binding-value b "source")))
                               (target . ,(compact-uri (get-binding-value b "target")))
                               (created . ,(get-binding-value b "created"))))
                           link-bindings))
               (result `((session_id . ,(compact-uri full-session-id))
                         (context . ,context-nodes)
                         (discoveries . ,discoveries)
                         (links . ,links))))

          (if (assoc-ref global-opts "json")
              (output-result result global-opts)
              (begin
                (format #t "\nSession history: ~a\n\n" (compact-uri full-session-id))
                (format #t "Context nodes:\n")
                (if (null? context-nodes)
                    (format #t "  (none)\n")
                    (for-each
                     (lambda (node) (format #t "  ~a\n" node))
                     context-nodes))
                (format #t "\nDiscoveries (~a):\n" (length discoveries))
                (if (null? discoveries)
                    (format #t "  (none)\n")
                    (for-each
                     (lambda (disc)
                       (format #t "  ~a  ~a  ~a\n"
                               (assoc-ref disc 'id)
                               (or (assoc-ref disc 'type) "")
                               (or (assoc-ref disc 'created) "")))
                     discoveries))
                (format #t "\nLinks (~a):\n" (length links))
                (if (null? links)
                    (format #t "  (none)\n")
                    (for-each
                     (lambda (lnk)
                       (format #t "  ~a  ~a -> ~a\n"
                               (assoc-ref lnk 'id)
                               (assoc-ref lnk 'source)
                               (assoc-ref lnk 'target)))
                     links)))))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time as ISO 8601 string."
  (date->string (time-utc->date (current-time time-utc))
                "~Y-~m-~dT~H:~M:~SZ"))

;; generate-uuid is imported from (xm store)

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))
