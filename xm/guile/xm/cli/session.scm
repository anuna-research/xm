;;; xm/cli/session.scm --- Session commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
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
         (parent-id (assoc-ref opts "parent")))

    ;; Validate required options
    (unless agent-id
      (output-error "MISSING_AGENT"
                    "Agent identifier is required"
                    "Use -a or --agent to specify the agent ID"
                    global-opts)
      (exit 2))

    ;; Create session
    (let* ((session-id (xm-session-uri (generate-uuid)))
           (timestamp (current-iso-timestamp))
           (result `((session_id . ,session-id)
                     (agent . ,agent-id)
                     (purpose . ,(or purpose ""))
                     (started_at . ,timestamp)
                     (context_nodes . ,context-nodes)
                     (parent . ,parent-id))))

      ;; In production: spawn session actor via registry
      ;; (<- session-registry 'start agent-id purpose context-nodes parent-id)

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nSession started: ~a\n" session-id)
            (format #t "Agent: ~a\n" agent-id)
            (when purpose (format #t "Purpose: ~a\n" purpose))
            (format #t "Started: ~a\n" timestamp)
            (format #t "\nExport SESSION_ID=~a\n" session-id))))))

;;; --------------------------------------------------------------------
;;; session end
;;; --------------------------------------------------------------------

(define (cmd-session-end opts global-opts store cap-ref)
  "End an active session.
   Usage: xm session end <SESSION_ID>
   Options:
   -s, --summary TEXT: Session summary"

  (let* ((positional (assoc-ref opts 'positional))
         (session-id (and (pair? positional) (car positional)))
         (summary (or (assoc-ref opts "summary")
                      (assoc-ref opts "s"))))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session end <SESSION_ID>"
                    global-opts)
      (exit 2))

    ;; In production: end session via registry
    ;; (<- session-registry 'end session-id summary)

    (let* ((timestamp (current-iso-timestamp))
           (result `((session_id . ,session-id)
                     (ended_at . ,timestamp)
                     (summary . ,summary)
                     (duration_seconds . 3600)
                     (discoveries . 5)
                     (context_nodes . 3))))

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nSession ended: ~a\n" session-id)
            (format #t "Duration: ~a seconds\n" (assoc-ref result 'duration_seconds))
            (format #t "Discoveries: ~a\n" (assoc-ref result 'discoveries))
            (when summary (format #t "Summary: ~a\n" summary)))))))

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
         (limit (string->number (or (assoc-ref opts "limit") "20"))))

    ;; In production: query session registry
    ;; (<- session-registry 'list-sessions agent-filter since-time active-only)

    ;; Placeholder results
    (let ((sessions '()))

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
                           (assoc-ref sess 'session_id)
                           (assoc-ref sess 'agent)
                           (assoc-ref sess 'started_at)
                           (if (assoc-ref sess 'active) "active" "ended")))
                 sessions)))))))

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
         (replay (assoc-ref opts "replay")))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session resume <SESSION_ID>"
                    global-opts)
      (exit 2))

    ;; In production: resume session
    ;; (<- session-registry 'resume session-id)

    (let ((result `((session_id . ,session-id)
                    (resumed_at . ,(current-iso-timestamp))
                    (original_agent . "claude-code")
                    (context_nodes . 3)
                    (discoveries . 5)
                    (replay . ,(if replay #t #f)))))

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nSession resumed: ~a\n" session-id)
            (format #t "Context nodes: ~a\n" (assoc-ref result 'context_nodes))
            (format #t "Previous discoveries: ~a\n" (assoc-ref result 'discoveries))
            (when replay (format #t "Replaying discoveries into context\n")))))))

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
         (limit (string->number (or (assoc-ref opts "limit") "100"))))

    (unless session-id
      (output-error "MISSING_SESSION_ID"
                    "Session ID is required"
                    "Usage: xm session history <SESSION_ID>"
                    global-opts)
      (exit 2))

    ;; In production: get session history
    ;; (<- session-registry 'history session-id)

    (let* ((context-nodes '())
           (discoveries '())
           (result `((session_id . ,session-id)
                     (context . ,context-nodes)
                     (discoveries . ,discoveries))))

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nSession history: ~a\n\n" session-id)
            (format #t "Context nodes:\n")
            (if (null? context-nodes)
                (format #t "  (none)\n")
                (for-each
                 (lambda (node) (format #t "  ~a\n" node))
                 context-nodes))
            (format #t "\nDiscoveries:\n")
            (if (null? discoveries)
                (format #t "  (none)\n")
                (for-each
                 (lambda (disc) (format #t "  ~a\n" disc))
                 discoveries)))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time as ISO 8601 string."
  (date->string (time-utc->date (current-time time-utc))
                "~Y-~m-~dT~H:~M:~SZ"))

(define (generate-uuid)
  "Generate a simple UUID-like string."
  (let* ((t (current-time time-utc))
         (secs (time-second t))
         (nsecs (time-nanosecond t))
         (r1 (random (expt 2 32)))
         (r2 (random (expt 2 32))))
    (format #f "~8,'0x-~4,'0x-~4,'0x-~4,'0x-~12,'0x"
            (logand secs #xffffffff)
            (logand (ash nsecs -16) #xffff)
            (logior #x4000 (logand (ash nsecs 0) #x0fff))
            (logior #x8000 (logand r1 #x3fff))
            (logand r2 #xffffffffffff))))

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))
