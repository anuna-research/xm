;;; xm/sync.scm --- Pubsub and synchronization primitives
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements the synchronization layer from SPEC-029 Section 4.7.
;;; It wraps the gatekeeper with change notifications and provides
;;; store-and-forward delivery guarantees.

(define-module (xm sync)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib pubsub)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-19)
  #:use-module (xm journal)
  #:export (;; Change notifier actor
            ^graph-change-notifier

            ;; Outbox actor for offline mutations
            ^outbox

            ;; Reliable sync actor
            ^reliable-sync))

;;; --------------------------------------------------------------------
;;; Graph Change Notifier Actor
;;; --------------------------------------------------------------------

(define (^graph-change-notifier bcom gatekeeper journal)
  "Actor wrapping gatekeeper with pubsub change notifications.
   From SPEC-029 Section 4.7.3: 'The Graph Gatekeeper maintains a pubsub
   actor for broadcasting graph mutations.'"

  ;; Create pubsub for change notifications
  (define change-pubsub (spawn ^pubsub))

  (define (current-iso-timestamp)
    (date->string (time-utc->date (current-time time-utc))
                  "~Y-~m-~dT~H:~M:~SZ"))

  (methods
   ;; Subscribe to changes (returns subscription handle)
   [(subscribe callback)
    (<- change-pubsub 'subscribe callback)]

   ;; Unsubscribe
   [(unsubscribe callback)
    (<- change-pubsub 'unsubscribe callback)]

   ;; Insert with notification
   [(insert cap-ref graph-uri triples-turtle #:optional agent-id)
    (let ((result (<- gatekeeper 'insert cap-ref graph-uri triples-turtle)))
      ;; Log to journal
      (<- journal 'append 'insert graph-uri triples-turtle
          (or agent-id "unknown"))
      ;; Notify subscribers
      (<- change-pubsub 'publish
          `((event . insert)
            (graph . ,graph-uri)
            (data . ,triples-turtle)
            (timestamp . ,(current-iso-timestamp))))
      result)]

   ;; Delete with notification
   [(delete cap-ref graph-uri pattern #:optional agent-id)
    (let ((result (<- gatekeeper 'delete cap-ref graph-uri pattern)))
      ;; Log to journal
      (<- journal 'append 'delete graph-uri pattern
          (or agent-id "unknown"))
      ;; Notify subscribers
      (<- change-pubsub 'publish
          `((event . delete)
            (graph . ,graph-uri)
            (pattern . ,pattern)
            (timestamp . ,(current-iso-timestamp))))
      result)]

   ;; Update with notification
   [(update cap-ref sparql #:optional agent-id)
    (let ((result (<- gatekeeper 'update cap-ref sparql)))
      ;; Log to journal
      (<- journal 'append 'update #f sparql
          (or agent-id "unknown"))
      ;; Notify subscribers
      (<- change-pubsub 'publish
          `((event . update)
            (sparql . ,sparql)
            (timestamp . ,(current-iso-timestamp))))
      result)]

   ;; Query (no notification, just passthrough)
   [(query cap-ref sparql)
    (<- gatekeeper 'query cap-ref sparql)]

   ;; Public query passthrough
   [(public-query sparql)
    (<- gatekeeper 'public-query sparql)]

   ;; Get underlying gatekeeper
   [(gatekeeper) gatekeeper]

   ;; Get journal
   [(journal) journal]))

;;; --------------------------------------------------------------------
;;; Outbox Actor for Offline Mutations
;;; --------------------------------------------------------------------

(define (^outbox bcom)
  "Actor managing local mutation queue for offline operation.
   From SPEC-029 Section 4.8.4: 'When an agent operates offline,
   mutations queue in a local outbox and replay on reconnect.'"

  ;; State: queue of pending mutations (list of (timestamp . mutation))
  (define queue '())

  (define (current-iso-timestamp)
    (date->string (time-utc->date (current-time time-utc))
                  "~Y-~m-~dT~H:~M:~SZ"))

  (methods
   ;; Queue mutation for later sync
   [(enqueue mutation)
    (set! queue (append queue
                        (list (cons (current-iso-timestamp) mutation))))
    (length queue)]

   ;; Peek at queued mutations without removing
   [(peek #:optional limit)
    (if limit
        (take-up-to queue limit)
        queue)]

   ;; Check pending count
   [(pending)
    (length queue)]

   ;; Check if empty
   [(empty?)
    (null? queue)]

   ;; Dequeue next mutation
   [(dequeue)
    (if (null? queue)
        #f
        (let ((item (car queue)))
          (set! queue (cdr queue))
          item))]

   ;; Flush outbox, applying mutations to remote
   [(flush remote-notifier cap-ref)
    (let loop ((results '()))
      (if (null? queue)
          (reverse results)
          (let* ((item (car queue))
                 (timestamp (car item))
                 (mutation (cdr item))
                 (result (apply-mutation remote-notifier cap-ref mutation)))
            (set! queue (cdr queue))
            (loop (cons `((timestamp . ,timestamp)
                          (result . ,result))
                        results)))))]

   ;; Clear all pending (use with caution)
   [(clear)
    (let ((count (length queue)))
      (set! queue '())
      count)]))

(define (apply-mutation notifier cap-ref mutation)
  "Apply a queued mutation to the notifier."
  (match mutation
    (('insert graph-uri triples)
     (<- notifier 'insert cap-ref graph-uri triples))
    (('delete graph-uri pattern)
     (<- notifier 'delete cap-ref graph-uri pattern))
    (('update sparql)
     (<- notifier 'update cap-ref sparql))
    (else
     (error "Unknown mutation type" mutation))))

;;; --------------------------------------------------------------------
;;; Reliable Sync Actor
;;; --------------------------------------------------------------------

(define (^reliable-sync bcom local-notifier subscriptions outbox)
  "Actor providing reliable bidirectional synchronization.
   From SPEC-029 Section 4.8.5: 'Combining journal, cursors, and outbox
   for guaranteed delivery.'"

  ;; State: remote endpoint reference (set via connect)
  (define remote-ref #f)

  ;; State: subscriber ID for this node
  (define my-subscriber-id #f)

  (methods
   ;; Connect to remote endpoint
   [(connect remote cap-ref subscriber-id)
    (set! remote-ref remote)
    (set! my-subscriber-id subscriber-id)
    ;; Subscribe to remote journal
    (<- remote 'subscribe subscriber-id (lambda (event)
                                           ;; Apply remote event locally
                                           (apply-event-locally local-notifier event)))
    #t]

   ;; Full sync: push local changes, pull remote changes
   [(sync cap-ref)
    (unless remote-ref
      (error "Not connected to remote"))
    (let ((push-results ($ bcom 'push-outbox cap-ref))
          (pull-results ($ bcom 'pull-pending cap-ref)))
      `((pushed . ,push-results)
        (pulled . ,pull-results)))]

   ;; Push queued local mutations to remote
   [(push-outbox cap-ref)
    (if remote-ref
        (<- outbox 'flush remote-ref cap-ref)
        '())]

   ;; Pull missed events from remote
   [(pull-pending cap-ref)
    (if (and remote-ref my-subscriber-id)
        (let ((events (<- remote-ref 'pending-for my-subscriber-id)))
          (for-each
           (lambda (event)
             (apply-event-locally local-notifier event)
             (<- remote-ref 'ack my-subscriber-id (journal-event-seq event)))
           events)
          (length events))
        0)]

   ;; Disconnect from remote
   [(disconnect)
    (when (and remote-ref my-subscriber-id)
      (<- remote-ref 'unsubscribe my-subscriber-id))
    (set! remote-ref #f)
    (set! my-subscriber-id #f)
    #t]

   ;; Check connection status
   [(connected?)
    (not (not remote-ref))]))

(define (apply-event-locally notifier event)
  "Apply a journal event to the local notifier."
  (let ((event-type (journal-event-type event))
        (graph-uri (journal-event-graph event))
        (data (journal-event-data event)))
    (case event-type
      ((insert)
       ;; Insert without capability (local trust)
       (<- notifier 'insert #f graph-uri data))
      ((delete)
       (<- notifier 'delete #f graph-uri data))
      (else
       ;; Ignore other event types for now
       #f))))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (take-up-to lst n)
  "Take up to N elements from LST."
  (let loop ((lst lst) (n n) (acc '()))
    (if (or (null? lst) (<= n 0))
        (reverse acc)
        (loop (cdr lst) (- n 1) (cons (car lst) acc)))))
