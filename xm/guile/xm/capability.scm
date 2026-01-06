;;; xm/capability.scm --- Object-capability management for xm
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements the capability model from SPEC-029 Section 4.5.
;;; Capabilities grant access to named graphs with specific permissions.

(define-module (xm capability)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-19)  ; time
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm vocabulary)
  #:export (;; Capability record
            <xm-capability>
            make-xm-capability
            xm-capability?
            capability-id
            capability-graphs
            capability-permissions
            capability-expires
            capability-created-by
            capability-label

            ;; Permission symbols
            permission-read
            permission-write
            permission-admin

            ;; Capability actor
            ^capability-store

            ;; Utility functions
            capability-expired?
            capability-has-permission?
            capability-allows-graph?
            capability-valid?
            permissions-subset?
            graphs-subset?))

;;; --------------------------------------------------------------------
;;; Permission Constants
;;; --------------------------------------------------------------------

(define permission-read 'read)
(define permission-write 'write)
(define permission-admin 'admin)

(define (valid-permission? p)
  (memq p (list permission-read permission-write permission-admin)))

;;; --------------------------------------------------------------------
;;; Capability Record Type
;;; --------------------------------------------------------------------

(define-record-type <xm-capability>
  (%make-xm-capability id graphs permissions expires created-by label)
  xm-capability?
  (id capability-id)                     ; String: xm:cap/{token}
  (graphs capability-graphs)             ; List of graph URIs
  (permissions capability-permissions)   ; List: '(read) | '(read write) | '(read write admin)
  (expires capability-expires)           ; #f or SRFI-19 time object
  (created-by capability-created-by)     ; Parent capability ID or #f for root
  (label capability-label))              ; Optional human-readable label

(set-record-type-printer! <xm-capability>
  (lambda (cap port)
    (format port "#<xm-capability ~a graphs:~a perms:~a>"
            (capability-id cap)
            (length (capability-graphs cap))
            (capability-permissions cap))))

(define* (make-xm-capability id graphs permissions
                              #:key expires created-by label)
  "Create a new capability record.
   ID: unique capability identifier (xm:cap/{token})
   GRAPHS: list of allowed named graph URIs
   PERMISSIONS: list of permission symbols (read, write, admin)
   EXPIRES: optional expiration time (SRFI-19 time or ISO 8601 string)
   CREATED-BY: optional parent capability ID
   LABEL: optional human-readable label"
  (let ((expires-time
         (cond
          ((not expires) #f)
          ((time? expires) expires)
          ((string? expires) (parse-iso8601-time expires))
          (else (error "Invalid expires value" expires)))))
    (%make-xm-capability id graphs permissions expires-time created-by label)))

;;; --------------------------------------------------------------------
;;; Time Utilities
;;; --------------------------------------------------------------------

(define (parse-iso8601-time str)
  "Parse an ISO 8601 timestamp string to SRFI-19 time."
  ;; Simple parser for common ISO 8601 formats
  (let ((date (string->date str "~Y-~m-~dT~H:~M:~S~z")))
    (date->time-utc date)))

(define (time->iso8601 time)
  "Convert SRFI-19 time to ISO 8601 string."
  (date->string (time-utc->date time) "~Y-~m-~dT~H:~M:~SZ"))

(define (current-time-utc)
  "Get current time as SRFI-19 time-utc."
  (current-time time-utc))

;;; --------------------------------------------------------------------
;;; Capability Validation
;;; --------------------------------------------------------------------

(define (capability-expired? cap)
  "Check if a capability has expired."
  (let ((expires (capability-expires cap)))
    (and expires
         (time<? expires (current-time-utc)))))

(define (capability-has-permission? cap perm)
  "Check if capability grants the specified permission."
  (memq perm (capability-permissions cap)))

(define (capability-allows-graph? cap graph-uri)
  "Check if capability allows access to the specified graph."
  (member graph-uri (capability-graphs cap)))

(define (capability-valid? cap)
  "Check if capability is valid (not expired)."
  (not (capability-expired? cap)))

(define (permissions-subset? child-perms parent-perms)
  "Check if child permissions are a subset of parent permissions."
  (every (lambda (p) (memq p parent-perms)) child-perms))

(define (graphs-subset? child-graphs parent-graphs)
  "Check if child graphs are a subset of parent graphs."
  (every (lambda (g) (member g parent-graphs)) child-graphs))

(define (every pred lst)
  "Return #t if PRED is true for every element of LST."
  (or (null? lst)
      (and (pred (car lst))
           (every pred (cdr lst)))))

;;; --------------------------------------------------------------------
;;; Capability Store Actor
;;; --------------------------------------------------------------------

(define (^capability-store bcom)
  "Actor that manages capabilities with persistence.
   Supports creation, attenuation, validation, and revocation."

  ;; State: hash table mapping capability ID to capability record
  (define caps (make-hash-table))

  ;; State: set of revoked capability IDs
  (define revoked (make-hash-table))

  ;; Generate a new capability token
  (define (generate-token)
    ;; Generate a simple UUID-like string
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

  (methods
   ;; Create a new root capability
   [(create graphs permissions #:optional expires label)
    (let* ((token (generate-token))
           (cap-id (xm-cap-uri token))
           (cap (make-xm-capability cap-id graphs permissions
                                     #:expires expires
                                     #:label label)))
      (hash-set! caps cap-id cap)
      cap)]

   ;; Attenuate an existing capability (create weaker child)
   [(attenuate parent-id #:optional graphs permissions expires label)
    (let ((parent (hash-ref caps parent-id #f)))
      (cond
       ((not parent)
        (error "Parent capability not found" parent-id))
       ((hash-ref revoked parent-id #f)
        (error "Parent capability has been revoked" parent-id))
       ((capability-expired? parent)
        (error "Parent capability has expired" parent-id))
       (else
        ;; Validate attenuation constraints
        (let ((child-graphs (or graphs (capability-graphs parent)))
              (child-perms (or permissions (capability-permissions parent)))
              (child-expires (or expires (capability-expires parent))))

          ;; Graphs must be subset
          (unless (graphs-subset? child-graphs (capability-graphs parent))
            (error "Child graphs must be subset of parent graphs"
                   child-graphs (capability-graphs parent)))

          ;; Permissions must be subset
          (unless (permissions-subset? child-perms (capability-permissions parent))
            (error "Child permissions must be subset of parent permissions"
                   child-perms (capability-permissions parent)))

          ;; Expiry must be earlier or equal
          (when (and child-expires (capability-expires parent))
            (unless (time<=? child-expires (capability-expires parent))
              (error "Child expiry must be earlier than parent expiry")))

          ;; Create attenuated capability
          (let* ((token (generate-token))
                 (cap-id (xm-cap-uri token))
                 (cap (make-xm-capability cap-id child-graphs child-perms
                                           #:expires child-expires
                                           #:created-by parent-id
                                           #:label label)))
            (hash-set! caps cap-id cap)
            cap)))))]

   ;; Validate a capability reference
   [(validate cap-id)
    (let ((cap (hash-ref caps cap-id #f)))
      (cond
       ((not cap)
        (values #f "Capability not found"))
       ((hash-ref revoked cap-id #f)
        (values #f "Capability has been revoked"))
       ((capability-expired? cap)
        (values #f "Capability has expired"))
       (else
        (values cap #f))))]

   ;; Get a capability by ID (without validation)
   [(get cap-id)
    (hash-ref caps cap-id #f)]

   ;; Revoke a capability
   [(revoke cap-id)
    (if (hash-ref caps cap-id #f)
        (begin
          (hash-set! revoked cap-id #t)
          #t)
        (error "Capability not found" cap-id))]

   ;; List all capabilities (optionally filtered)
   [(list-all #:optional include-revoked include-expired)
    (let ((all-caps (hash-map->list (lambda (k v) v) caps)))
      (filter
       (lambda (cap)
         (and (or include-revoked
                  (not (hash-ref revoked (capability-id cap) #f)))
              (or include-expired
                  (not (capability-expired? cap)))))
       all-caps))]

   ;; Get capabilities created by a specific parent
   [(children-of parent-id)
    (filter
     (lambda (cap)
       (equal? (capability-created-by cap) parent-id))
     (hash-map->list (lambda (k v) v) caps))]

   ;; Check if capability allows operation on graph
   [(check-access cap-id graph-uri permission)
    (let-values (((cap err) ($ bcom 'validate cap-id)))
      (if err
          (values #f err)
          (cond
           ((not (capability-allows-graph? cap graph-uri))
            (values #f (format #f "Graph ~a not in capability scope" graph-uri)))
           ((not (capability-has-permission? cap permission))
            (values #f (format #f "Permission ~a not granted" permission)))
           (else
            (values #t #f)))))]))

(define (time<=? t1 t2)
  "Check if time t1 is less than or equal to time t2."
  (or (time<? t1 t2)
      (time=? t1 t2)))
