;;; xm/journal.scm --- Event journal for store-and-forward messaging
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; The Event Journal is an append-only log of all graph mutations.
;;; From SPEC-029 Section 4.8.2: "The Event Journal is an append-only log
;;; of all graph mutations, stored in Bloblin for durability."

(define-module (xm journal)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-19)  ; time
  #:export (;; Event record
            <journal-event>
            make-journal-event
            journal-event?
            journal-event-seq
            journal-event-timestamp
            journal-event-type
            journal-event-graph
            journal-event-data
            journal-event-agent

            ;; Event journal actor
            ^event-journal

            ;; Subscription registry actor
            ^subscription-registry))

;;; --------------------------------------------------------------------
;;; Event Record Type
;;; --------------------------------------------------------------------

(define-record-type <journal-event>
  (make-journal-event seq timestamp event-type graph-uri data agent-id)
  journal-event?
  (seq journal-event-seq)              ; Monotonic sequence number
  (timestamp journal-event-timestamp)  ; ISO 8601 string
  (event-type journal-event-type)      ; 'insert | 'delete | 'clear
  (graph-uri journal-event-graph)      ; Affected graph
  (data journal-event-data)            ; Triples or pattern data
  (agent-id journal-event-agent))      ; Who made the change

(set-record-type-printer! <journal-event>
  (lambda (ev port)
    (format port "#<journal-event seq:~a ~a ~a>"
            (journal-event-seq ev)
            (journal-event-type ev)
            (journal-event-graph ev))))

;;; --------------------------------------------------------------------
;;; Event Journal Actor
;;; --------------------------------------------------------------------

(define (^event-journal bcom)
  "Actor managing the append-only event journal.
   Provides append, read-from, and compaction operations."

  ;; State: next sequence number (monotonically increasing)
  (define next-seq 1)

  ;; State: event list (in memory; in production, persisted via Bloblin)
  ;; Events stored newest-first for efficient appending
  (define events '())

  ;; State: archived event ranges (for compaction tracking)
  (define archived-ranges '())

  (define (current-iso-timestamp)
    (date->string (time-utc->date (current-time time-utc))
                  "~Y-~m-~dT~H:~M:~SZ"))

  (methods
   ;; Append a new event to the journal
   [(append event-type graph-uri data agent-id)
    (let* ((seq next-seq)
           (event (make-journal-event
                   seq
                   (current-iso-timestamp)
                   event-type
                   graph-uri
                   data
                   agent-id)))
      (set! next-seq (+ seq 1))
      (set! events (cons event events))
      seq)]

   ;; Read events from a sequence number (inclusive)
   [(read-from start-seq #:optional (limit 1000))
    (let ((filtered (filter (lambda (e)
                              (>= (journal-event-seq e) start-seq))
                            (reverse events))))
      (take-up-to filtered limit))]

   ;; Get current head sequence number
   [(head-seq)
    (- next-seq 1)]

   ;; Get oldest available sequence (after compaction)
   [(oldest-seq)
    (if (null? events)
        0
        (journal-event-seq (last events)))]

   ;; Get event count
   [(count)
    (length events)]

   ;; Compact old events (move to archive, keep recent)
   [(compact before-seq)
    (let-values (((keep archive) (partition
                                  (lambda (e)
                                    (>= (journal-event-seq e) before-seq))
                                  events)))
      (set! events keep)
      ;; Record archived range
      (unless (null? archive)
        (let ((oldest (journal-event-seq (last archive)))
              (newest (journal-event-seq (car archive))))
          (set! archived-ranges
                (cons `((from . ,oldest) (to . ,newest)) archived-ranges))))
      `((compacted . ,(length archive))
        (remaining . ,(length keep))
        (oldest-available . ,(if (null? keep) 0 (journal-event-seq (last keep))))))]

   ;; Get specific event by sequence number
   [(get-event seq)
    (find (lambda (e) (= (journal-event-seq e) seq)) events)]

   ;; Serialize journal to list (for persistence)
   [(to-list)
    (reverse events)]

   ;; Restore from list (for persistence)
   [(from-list event-list)
    (set! events (reverse event-list))
    (set! next-seq (if (null? events)
                       1
                       (+ 1 (journal-event-seq (car events)))))
    #t]))

;;; --------------------------------------------------------------------
;;; Subscription Registry Actor
;;; --------------------------------------------------------------------

(define (^subscription-registry bcom journal)
  "Actor managing subscriber cursors for event delivery.
   From SPEC-029 Section 4.8.3: 'Each subscriber maintains a cursor
   (last-seen sequence number)'"

  ;; State: hash table mapping subscriber-id -> cursor (last-seen seq)
  (define cursors (make-hash-table))

  ;; State: hash table mapping subscriber-id -> callback
  (define callbacks (make-hash-table))

  (methods
   ;; Register new subscriber, optionally from specific sequence
   [(subscribe subscriber-id callback #:optional from-seq)
    (let ((start-seq (or from-seq (<- journal 'head-seq))))
      (hash-set! cursors subscriber-id start-seq)
      (hash-set! callbacks subscriber-id callback)
      ;; Return starting position
      start-seq)]

   ;; Update cursor after successful delivery
   [(ack subscriber-id seq)
    (let ((current (hash-ref cursors subscriber-id 0)))
      (when (> seq current)
        (hash-set! cursors subscriber-id seq))
      #t)]

   ;; Get events subscriber hasn't seen
   [(pending-for subscriber-id)
    (let ((cursor (hash-ref cursors subscriber-id 0)))
      (<- journal 'read-from (+ cursor 1)))]

   ;; Get cursor position for subscriber
   [(cursor-for subscriber-id)
    (hash-ref cursors subscriber-id #f)]

   ;; Unsubscribe
   [(unsubscribe subscriber-id)
    (hash-remove! cursors subscriber-id)
    (hash-remove! callbacks subscriber-id)
    #t]

   ;; List all subscribers
   [(list-subscribers)
    (hash-map->list (lambda (k v)
                      `((id . ,k) (cursor . ,v)))
                    cursors)]

   ;; Check if cursor has expired (events compacted)
   [(cursor-expired? subscriber-id)
    (let ((cursor (hash-ref cursors subscriber-id #f))
          (oldest (<- journal 'oldest-seq)))
      (and cursor (< cursor oldest)))]

   ;; Deliver pending events to subscriber (calls callback)
   [(deliver-to subscriber-id)
    (let ((callback (hash-ref callbacks subscriber-id #f))
          (pending ($ bcom 'pending-for subscriber-id)))
      (if callback
          (begin
            (for-each
             (lambda (event)
               (callback event)
               ($ bcom 'ack subscriber-id (journal-event-seq event)))
             pending)
            (length pending))
          0))]))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (take-up-to lst n)
  "Take up to N elements from LST."
  (let loop ((lst lst) (n n) (acc '()))
    (if (or (null? lst) (<= n 0))
        (reverse acc)
        (loop (cdr lst) (- n 1) (cons (car lst) acc)))))

(define (partition pred lst)
  "Partition LST into two lists based on PRED."
  (let loop ((lst lst) (yes '()) (no '()))
    (if (null? lst)
        (values (reverse yes) (reverse no))
        (if (pred (car lst))
            (loop (cdr lst) (cons (car lst) yes) no)
            (loop (cdr lst) yes (cons (car lst) no))))))

(define (find pred lst)
  "Find first element in LST satisfying PRED, or #f."
  (cond
   ((null? lst) #f)
   ((pred (car lst)) (car lst))
   (else (find pred (cdr lst)))))

(define (last lst)
  "Get last element of LST."
  (if (null? (cdr lst))
      (car lst)
      (last (cdr lst))))
