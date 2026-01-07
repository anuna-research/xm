;;; xm/capability.scm --- Object-capability management for xm
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This module implements proper Goblins-style object capabilities.
;;;
;;; KEY INSIGHT: In Goblins, capabilities ARE actor references.
;;; - If you have a reference to an actor, you can call its methods
;;; - Attenuation = spawn a wrapper (facet) actor with restricted behavior
;;; - The facet IS the attenuated capability
;;; - For network sharing: register actor → get sturdyref → share URI
;;;
;;; This differs from the original SPEC-029 design which incorrectly
;;; treated capabilities as database records with permission lists.

(define-module (xm capability)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)   ; list operations
  #:use-module (srfi srfi-19)  ; time
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm vocabulary)
  #:export (;; Graph facet constructors
            ^graph-facet
            ^read-only-graph-facet
            ^write-graph-facet
            ^admin-graph-facet

            ;; Capability registry (for CLI naming)
            ^capability-registry

            ;; Utility predicates
            permission-read
            permission-write
            permission-admin
            valid-permission?

            ;; Time utilities
            capability-expired?
            make-expiring-facet))

;;; ====================================================================
;;; GOBLINS CAPABILITY MODEL
;;; ====================================================================
;;;
;;; In Goblins, capabilities work as follows:
;;;
;;; 1. A capability IS an actor reference
;;;    - If you have the reference, you can call its methods
;;;    - No separate "permission tokens" or "capability IDs"
;;;
;;; 2. Attenuation via facets
;;;    - To weaken a capability, spawn a wrapper actor
;;;    - The wrapper exposes fewer methods or adds constraints
;;;    - The wrapper IS the attenuated capability
;;;
;;; 3. Sharing over network
;;;    - Register actor with mycapn: (<- mycapn 'register actor 'onion)
;;;    - Get sturdyref URI: (ocapn-id->string sturdyref)
;;;    - Share URI out-of-band
;;;    - Receiver enlivens: (<- mycapn 'enliven (string->ocapn-id uri))
;;;
;;; 4. Revocation
;;;    - Actor can check a "revoked" cell before each operation
;;;    - Or use sealer/unsealer patterns
;;;
;;; ====================================================================

;;; --------------------------------------------------------------------
;;; Permission Symbols (for documentation/type-checking only)
;;; --------------------------------------------------------------------

(define permission-read 'read)
(define permission-write 'write)
(define permission-admin 'admin)

(define (valid-permission? p)
  "Check if P is a valid permission symbol."
  (memq p (list permission-read permission-write permission-admin)))

;;; --------------------------------------------------------------------
;;; Graph Facet - The Core Capability Actor
;;; --------------------------------------------------------------------
;;;
;;; A graph facet wraps a gatekeeper and restricts access to:
;;; - Specific named graphs
;;; - Specific operations (read/write/admin)
;;; - Optional expiration time
;;;
;;; The facet IS the capability - whoever has the actor reference
;;; can perform the allowed operations.

(define* (^graph-facet bcom gatekeeper allowed-graphs allowed-ops
                       #:key expires revoked-cell label)
  "Create a graph facet actor that wraps GATEKEEPER.

   GATEKEEPER: the underlying graph gatekeeper actor
   ALLOWED-GRAPHS: list of graph URIs this facet can access
   ALLOWED-OPS: list of allowed operations ('read 'write 'admin)
   EXPIRES: optional expiration time (SRFI-19 time-utc)
   REVOKED-CELL: optional cell to check for revocation
   LABEL: optional human-readable label

   The facet IS the capability - the actor reference grants access.
   Attenuation is achieved by spawning facets with stricter constraints."

  ;; Check revocation
  (define (check-revoked)
    (when (and revoked-cell ($ revoked-cell))
      (error 'capability-revoked "This capability has been revoked")))

  ;; Check expiration
  (define (check-expired)
    (when (and expires (time<? expires (current-time time-utc)))
      (error 'capability-expired "This capability has expired")))

  ;; Validate operation is allowed
  (define (check-op op)
    (unless (memq op allowed-ops)
      (error 'operation-not-permitted
             (format #f "Operation '~a' not permitted by this capability" op))))

  ;; Validate graph is allowed
  (define (check-graph graph-uri)
    (unless (member graph-uri allowed-graphs)
      (error 'graph-not-permitted
             (format #f "Graph '~a' not permitted by this capability" graph-uri))))

  ;; Common validation
  (define (validate op . graphs)
    (check-revoked)
    (check-expired)
    (check-op op)
    (for-each check-graph graphs))

  (methods
   ;;; --- Introspection ---

   ;; Get capability metadata (for CLI display)
   [(info)
    `((graphs . ,allowed-graphs)
      (operations . ,allowed-ops)
      (expires . ,(and expires (time->iso8601 expires)))
      (label . ,label))]

   ;; Get allowed graphs
   [(allowed-graphs) allowed-graphs]

   ;; Get allowed operations
   [(allowed-operations) allowed-ops]

   ;;; --- Read Operations ---

   ;; Execute SPARQL query (scoped to allowed graphs)
   [(query sparql)
    (validate 'read)
    ;; Delegate to gatekeeper with our allowed graphs
    (<- gatekeeper 'query-with-graphs sparql allowed-graphs)]

   ;; Dump a graph to RDF format
   [(dump-graph graph-uri rdf-format)
    (validate 'read graph-uri)
    (<- gatekeeper 'dump-graph-internal graph-uri rdf-format)]

   ;;; --- Write Operations ---

   ;; Insert triples into a graph
   [(insert graph-uri triples-turtle)
    (validate 'write graph-uri)
    (<- gatekeeper 'insert-internal graph-uri triples-turtle)]

   ;; Execute SPARQL UPDATE
   [(update sparql)
    (validate 'write)
    ;; Extract graphs from UPDATE and validate each
    (let ((update-graphs (extract-graphs-from-update sparql)))
      (for-each (lambda (g) (check-graph g)) update-graphs))
    (<- gatekeeper 'update-internal sparql)]

   ;; Delete triples matching pattern
   [(delete graph-uri pattern-sparql)
    (validate 'write graph-uri)
    (<- gatekeeper 'delete-internal graph-uri pattern-sparql)]

   ;;; --- Admin Operations ---

   ;; Clear an entire graph
   [(clear-graph graph-uri)
    (validate 'admin graph-uri)
    (<- gatekeeper 'clear-graph-internal graph-uri)]

   ;; Create a new graph
   [(create-graph graph-uri)
    (validate 'admin)
    (<- gatekeeper 'create-graph-internal graph-uri)]

   ;;; --- Attenuation ---

   ;; Create an attenuated facet (weaker capability)
   ;; This is the KEY to Goblins capability model:
   ;; Attenuation = spawn a new actor with stricter constraints
   [(attenuate #:key graphs ops new-expires new-label)
    (check-revoked)
    (check-expired)

    ;; New graphs must be subset of current
    (let ((child-graphs (or graphs allowed-graphs)))
      (unless (lset<= string=? child-graphs allowed-graphs)
        (error 'invalid-attenuation
               "Cannot grant graphs not in parent capability"))

      ;; New ops must be subset of current
      (let ((child-ops (or ops allowed-ops)))
        (unless (lset<= eq? child-ops allowed-ops)
          (error 'invalid-attenuation
                 "Cannot grant operations not in parent capability"))

        ;; New expiry must be earlier or equal
        (let ((child-expires (or new-expires expires)))
          (when (and expires child-expires)
            (unless (time<=? child-expires expires)
              (error 'invalid-attenuation
                     "Cannot extend expiration beyond parent")))

          ;; Spawn the attenuated facet
          ;; The new actor reference IS the attenuated capability
          (spawn ^graph-facet gatekeeper child-graphs child-ops
                 #:expires child-expires
                 #:revoked-cell revoked-cell  ; inherit revocation
                 #:label new-label))))]))

;;; --------------------------------------------------------------------
;;; Convenience Facet Constructors
;;; --------------------------------------------------------------------

(define* (^read-only-graph-facet bcom gatekeeper graphs
                                  #:key expires revoked-cell label)
  "Create a read-only facet for the specified graphs."
  (^graph-facet bcom gatekeeper graphs '(read)
                #:expires expires
                #:revoked-cell revoked-cell
                #:label (or label "Read-only access")))

(define* (^write-graph-facet bcom gatekeeper graphs
                              #:key expires revoked-cell label)
  "Create a read+write facet for the specified graphs."
  (^graph-facet bcom gatekeeper graphs '(read write)
                #:expires expires
                #:revoked-cell revoked-cell
                #:label (or label "Read/write access")))

(define* (^admin-graph-facet bcom gatekeeper graphs
                              #:key expires revoked-cell label)
  "Create a full-access facet for the specified graphs."
  (^graph-facet bcom gatekeeper graphs '(read write admin)
                #:expires expires
                #:revoked-cell revoked-cell
                #:label (or label "Admin access")))

;;; --------------------------------------------------------------------
;;; Expiring Facet Wrapper
;;; --------------------------------------------------------------------

(define* (make-expiring-facet facet duration-seconds)
  "Wrap a facet with an expiration time.
   Returns a new facet that expires after DURATION-SECONDS."
  (let ((expires (add-duration (current-time time-utc)
                               (make-time time-duration 0 duration-seconds))))
    (<- facet 'attenuate #:new-expires expires)))

;;; --------------------------------------------------------------------
;;; Capability Registry
;;; --------------------------------------------------------------------
;;;
;;; Since Goblins capabilities are actor references (not strings),
;;; we need a registry for CLI usability. The registry:
;;; - Maps human-readable labels to actor references
;;; - Stores sturdyref URIs for persistence
;;; - Enables "xm cap list" and "xm cap inspect <label>" commands

(define (^capability-registry bcom)
  "Actor that maintains a registry of named capabilities.

   This bridges the Goblins actor model with CLI usability:
   - Capabilities are stored by label (human-readable name)
   - Sturdyref URIs are stored for persistence across restarts
   - Lookups return live actor references

   NOTE: The registry itself is an actor. Having a reference to the
   registry gives you the ability to look up capabilities by name."

  ;; State: label -> (capability-ref . sturdyref-uri-or-#f)
  (define registry (make-hash-table))

  ;; State: set of revoked labels
  (define revoked (make-hash-table))

  (methods
   ;; Register a capability with a label
   ;; Returns the label for confirmation
   [(register label capability-ref #:optional sturdyref-uri)
    (hash-set! registry label (cons capability-ref sturdyref-uri))
    label]

   ;; Look up a capability by label
   ;; Returns the actor reference (the capability itself)
   [(lookup label)
    (if (hash-ref revoked label #f)
        (error 'capability-revoked
               (format #f "Capability '~a' has been revoked" label))
        (let ((entry (hash-ref registry label #f)))
          (if entry
              (car entry)  ; Return the actor reference
              (error 'capability-not-found
                     (format #f "No capability named '~a'" label)))))]

   ;; Get sturdyref URI for a capability (for sharing)
   [(get-sturdyref label)
    (let ((entry (hash-ref registry label #f)))
      (if entry
          (cdr entry)  ; Return the sturdyref URI
          #f))]

   ;; Update sturdyref for a capability (after registration with mycapn)
   [(set-sturdyref label uri)
    (let ((entry (hash-ref registry label #f)))
      (when entry
        (hash-set! registry label (cons (car entry) uri))))]

   ;; List all registered capabilities
   [(list-all #:optional include-revoked)
    (let ((all-labels (hash-map->list (lambda (k v) k) registry)))
      (if include-revoked
          all-labels
          (filter (lambda (l) (not (hash-ref revoked l #f))) all-labels)))]

   ;; Get info about a capability
   [(info label)
    (let ((entry (hash-ref registry label #f)))
      (if entry
          (let ((cap-ref (car entry))
                (sref (cdr entry)))
            `((label . ,label)
              (sturdyref . ,sref)
              (revoked . ,(hash-ref revoked label #f))
              ;; Get capability's own info
              (capability-info . ,(<- cap-ref 'info))))
          #f))]

   ;; Revoke a capability by label
   ;; Note: This marks it revoked in the registry, but the underlying
   ;; facet should also have a revoked-cell for proper revocation
   [(revoke label)
    (if (hash-ref registry label #f)
        (begin
          (hash-set! revoked label #t)
          #t)
        (error 'capability-not-found
               (format #f "No capability named '~a'" label)))]

   ;; Check if a label exists
   [(exists? label)
    (and (hash-ref registry label #f) #t)]

   ;; Remove a capability from registry entirely
   [(unregister label)
    (hash-remove! registry label)
    (hash-remove! revoked label)]))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (extract-graphs-from-update sparql)
  "Extract graph URIs from a SPARQL UPDATE query."
  ;; Simple regex extraction - matches GRAPH <uri>
  (let ((rx (make-regexp "GRAPH\\s*<([^>]+)>" regexp/icase)))
    (let loop ((start 0) (graphs '()))
      (let ((m (regexp-exec rx sparql start)))
        (if m
            (loop (match:end m)
                  (cons (match:substring m 1) graphs))
            (reverse graphs))))))

(define (time->iso8601 time)
  "Convert SRFI-19 time to ISO 8601 string."
  (date->string (time-utc->date time) "~Y-~m-~dT~H:~M:~SZ"))

(define (time<=? t1 t2)
  "Check if time t1 is less than or equal to time t2."
  (or (time<? t1 t2) (time=? t1 t2)))

(define (capability-expired? expires)
  "Check if an expiration time has passed."
  (and expires (time<? expires (current-time time-utc))))

;;; SRFI-1 compatibility
(define (lset<= = set1 set2)
  "Check if SET1 is a subset of SET2 using = for comparison."
  (every (lambda (x) (member x set2 =)) set1))

(define (filter pred lst)
  "Keep elements where PRED returns true."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (if (pred (car lst))
            (loop (cdr lst) (cons (car lst) acc))
            (loop (cdr lst) acc)))))

(define (every pred lst)
  "Return #t if PRED is true for every element of LST."
  (or (null? lst)
      (and (pred (car lst))
           (every pred (cdr lst)))))

;;; Import regexp for extract-graphs-from-update
(use-modules (ice-9 regex))
