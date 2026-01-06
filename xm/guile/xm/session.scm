;;; xm/session.scm --- Session management for agent interactions
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Sessions group related interactions and automatically link discoveries.
;;; From SPEC-029 Section 4.6: "Sessions group related interactions and
;;; automatically link discoveries."

(define-module (xm session)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-19)  ; time
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm vocabulary)
  #:export (;; Session record
            <xm-session>
            make-xm-session
            xm-session?
            session-id
            session-agent-id
            session-purpose
            session-started-at
            session-ended-at
            session-context
            session-discoveries
            session-parent
            session-summary

            ;; Session actor
            ^session-actor

            ;; Session registry actor
            ^session-registry))

;;; --------------------------------------------------------------------
;;; Session Record Type
;;; --------------------------------------------------------------------

(define-record-type <xm-session>
  (%make-xm-session id agent-id purpose started-at ended-at
                    context discoveries parent summary)
  xm-session?
  (id session-id)                    ; xm:session/{uuid}
  (agent-id session-agent-id)        ; Agent that started this session
  (purpose session-purpose)          ; Human-readable description
  (started-at session-started-at)    ; SRFI-19 time
  (ended-at session-ended-at)        ; #f if active, time if ended
  (context session-context)          ; List of context node URIs
  (discoveries session-discoveries)  ; List of nodes/links created
  (parent session-parent)            ; Parent session ID or #f
  (summary session-summary))         ; Summary text (set on end)

(set-record-type-printer! <xm-session>
  (lambda (sess port)
    (format port "#<xm-session ~a agent:~a ~a>"
            (session-id sess)
            (session-agent-id sess)
            (if (session-ended-at sess) "ended" "active"))))

(define* (make-xm-session id agent-id purpose
                           #:key started-at context parent)
  "Create a new session record."
  (%make-xm-session
   id
   agent-id
   purpose
   (or started-at (current-time time-utc))
   #f    ; ended-at
   (or context '())
   '()   ; discoveries
   parent
   #f))  ; summary

;;; --------------------------------------------------------------------
;;; UUID Generator
;;; --------------------------------------------------------------------

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

;;; --------------------------------------------------------------------
;;; Session Actor
;;; --------------------------------------------------------------------

(define (^session-actor bcom gatekeeper agent-id purpose #:optional parent-id)
  "Actor managing a single session's lifecycle.
   GATEKEEPER: the graph gatekeeper actor for recording session data
   AGENT-ID: identifier of the agent owning this session
   PURPOSE: human-readable description of the session
   PARENT-ID: optional parent session for continuations"

  ;; Generate session ID
  (define session-id (xm-session-uri (generate-uuid)))

  ;; Session state
  (define context-nodes '())
  (define discoveries '())
  (define started-at (current-time time-utc))
  (define ended-at #f)
  (define summary #f)

  ;; Create session graph
  (define session-graph (xm-graph-uri "session" (generate-uuid)))

  (methods
   ;; Get session ID
   [(id) session-id]

   ;; Get session graph URI
   [(graph) session-graph]

   ;; Check if session is active
   [(active?) (not ended-at)]

   ;; Add context node
   [(add-context node-id)
    (unless ended-at
      (set! context-nodes (cons node-id context-nodes))
      node-id)]

   ;; Get context nodes
   [(get-context) context-nodes]

   ;; Record a discovery (node or link created during session)
   [(record-discovery discovery-uri)
    (unless ended-at
      (set! discoveries (cons discovery-uri discoveries))
      ;; Link discovery to session via prov:wasGeneratedBy
      (let ((triple (format #f "<~a> <~a> <~a> ."
                            discovery-uri
                            prov:wasGeneratedBy
                            session-id)))
        ;; Note: In production, this would go through the gatekeeper
        ;; with appropriate capability
        )
      discovery-uri)]

   ;; Get discoveries
   [(get-discoveries) discoveries]

   ;; End the session
   [(end #:optional end-summary)
    (unless ended-at
      (set! ended-at (current-time time-utc))
      (set! summary end-summary)
      ;; Return session stats
      `((session-id . ,session-id)
        (agent . ,agent-id)
        (purpose . ,purpose)
        (duration-seconds . ,(time-duration->seconds
                              (time-difference ended-at started-at)))
        (context-nodes . ,(length context-nodes))
        (discoveries . ,(length discoveries))
        (summary . ,summary)))]

   ;; Get session summary/stats
   [(stats)
    `((session-id . ,session-id)
      (agent . ,agent-id)
      (purpose . ,purpose)
      (started-at . ,(time->iso8601 started-at))
      (ended-at . ,(and ended-at (time->iso8601 ended-at)))
      (active . ,(not ended-at))
      (context-nodes . ,context-nodes)
      (discoveries . ,discoveries)
      (summary . ,summary))]

   ;; Serialize to record
   [(to-record)
    (%make-xm-session session-id agent-id purpose started-at ended-at
                      context-nodes discoveries parent-id summary)]))

;;; --------------------------------------------------------------------
;;; Session Registry Actor
;;; --------------------------------------------------------------------

(define (^session-registry bcom gatekeeper)
  "Actor managing all sessions.
   Handles creation, lookup, and listing of sessions."

  ;; State: hash table mapping session ID to session actor
  (define sessions (make-hash-table))

  ;; State: current session per agent
  (define current-sessions (make-hash-table))

  (methods
   ;; Start a new session
   [(start agent-id purpose #:optional context-nodes parent-id)
    (let ((session (spawn ^session-actor gatekeeper agent-id purpose parent-id)))
      ;; Add context nodes if provided
      (when context-nodes
        (for-each (lambda (node) (<- session 'add-context node))
                  context-nodes))
      ;; Register session
      (let ((session-id (<- session 'id)))
        (hash-set! sessions session-id session)
        (hash-set! current-sessions agent-id session-id)
        session))]

   ;; Get session by ID
   [(get session-id)
    (hash-ref sessions session-id #f)]

   ;; Get current session for agent
   [(current-for-agent agent-id)
    (let ((session-id (hash-ref current-sessions agent-id #f)))
      (and session-id (hash-ref sessions session-id #f)))]

   ;; End a session
   [(end session-id #:optional summary)
    (let ((session (hash-ref sessions session-id #f)))
      (if session
          (let ((result (<- session 'end summary)))
            ;; Clear current session if this was it
            (let ((agent (assoc-ref result 'agent)))
              (when (equal? (hash-ref current-sessions agent #f) session-id)
                (hash-remove! current-sessions agent)))
            result)
          (error "Session not found" session-id)))]

   ;; Resume a previous session
   [(resume session-id)
    (let ((session (hash-ref sessions session-id #f)))
      (if session
          (if (<- session 'active?)
              session
              (error "Cannot resume ended session" session-id))
          (error "Session not found" session-id)))]

   ;; List sessions (with optional filters)
   [(list-sessions #:optional agent-id since-time active-only)
    (let ((all-sessions (hash-map->list (lambda (k v) v) sessions)))
      (filter
       (lambda (session)
         (let ((stats (<- session 'stats)))
           (and (or (not agent-id)
                    (equal? (assoc-ref stats 'agent) agent-id))
                (or (not since-time)
                    (time>=? (string->time (assoc-ref stats 'started-at))
                             since-time))
                (or (not active-only)
                    (assoc-ref stats 'active)))))
       all-sessions))]

   ;; Get session history (nodes/links created)
   [(history session-id)
    (let ((session (hash-ref sessions session-id #f)))
      (if session
          `((session-id . ,session-id)
            (context . ,(<- session 'get-context))
            (discoveries . ,(<- session 'get-discoveries)))
          (error "Session not found" session-id)))]))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (time-duration->seconds duration)
  "Convert a time-duration to seconds."
  (+ (time-second duration)
     (/ (time-nanosecond duration) 1e9)))

(define (time->iso8601 t)
  "Convert SRFI-19 time to ISO 8601 string."
  (date->string (time-utc->date t) "~Y-~m-~dT~H:~M:~SZ"))

(define (string->time str)
  "Parse ISO 8601 string to SRFI-19 time."
  (date->time-utc (string->date str "~Y-~m-~dT~H:~M:~S~z")))

(define (time>=? t1 t2)
  "Check if time t1 >= time t2."
  (or (time>? t1 t2) (time=? t1 t2)))
