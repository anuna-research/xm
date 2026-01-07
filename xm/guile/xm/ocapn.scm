;;; xm/ocapn.scm --- OCapN network capability support for xm
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This module provides network capability sharing using Spritely Goblins'
;;; OCapN (Object Capability Network) protocol.
;;;
;;; KEY CONCEPTS:
;;;
;;; 1. STURDYREFS - Persistent, shareable capability references
;;;    - An actor reference can be converted to a sturdyref URI
;;;    - The URI can be shared out-of-band (email, config file, etc.)
;;;    - Remote peers "enliven" the sturdyref to get a live reference
;;;
;;; 2. MYCAPN - The OCapN coordinator
;;;    - Manages netlayer connections
;;;    - Registers actors to create sturdyrefs
;;;    - Enlivens sturdyrefs to get remote references
;;;
;;; 3. NETLAYERS - Transport mechanisms
;;;    - Tor Onion Services (^onion-netlayer)
;;;    - TCP + TLS (^tcp-tls-netlayer)
;;;    - Unix domain sockets (^unix-domain-socket-netlayer)
;;;    - WebSocket (^websocket-netlayer)
;;;
;;; USAGE:
;;;
;;;   ;; Server side: create and share a capability
;;;   (define cap (spawn ^graph-facet gatekeeper graphs ops))
;;;   (define sref (<- mycapn 'register cap 'onion))
;;;   (define uri (ocapn-id->string sref))
;;;   ;; Share URI out-of-band...
;;;
;;;   ;; Client side: enliven the capability
;;;   (define remote-cap (<- mycapn 'enliven (string->ocapn-id uri)))
;;;   (<- remote-cap 'query "SELECT ...")

(define-module (xm ocapn)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins ocapn captp)
  #:use-module (goblins ocapn ids)
  #:use-module (ice-9 format)
  #:export (;; Sturdyref conversion
            sturdyref->string
            string->sturdyref

            ;; OCapN daemon
            ^xm-ocapn-daemon

            ;; Convenience functions
            make-sturdyref-for-capability
            enliven-sturdyref))

;;; --------------------------------------------------------------------
;;; Sturdyref String Conversion
;;; --------------------------------------------------------------------

(define (sturdyref->string sref)
  "Convert a sturdyref to a shareable URI string.
   The string can be shared out-of-band and used to enliven
   the capability on another machine."
  (ocapn-id->string sref))

(define (string->sturdyref uri)
  "Parse a sturdyref URI string back into a sturdyref object."
  (string->ocapn-id uri))

;;; --------------------------------------------------------------------
;;; XM OCapN Daemon
;;; --------------------------------------------------------------------
;;;
;;; The daemon manages OCapN connections and provides a registry for
;;; named capabilities. This bridges the Goblins actor model with CLI
;;; usability - capabilities can be registered with human-readable names
;;; and their sturdyrefs stored for persistence.

(define (^xm-ocapn-daemon bcom mycapn)
  "Create an xm OCapN daemon actor.

   MYCAPN: the ^mycapn coordinator actor from (goblins ocapn captp)

   The daemon provides:
   - Registration of capabilities with labels
   - Sturdyref storage for persistence
   - Lookup by label for CLI commands"

  ;; State: label -> (capability-ref . sturdyref-or-#f)
  (define registry (make-hash-table))

  ;; State: sturdyref-string -> label (reverse lookup)
  (define uri->label (make-hash-table))

  (methods
   ;; Register a capability with a human-readable label
   ;; Optionally register with a netlayer to get a sturdyref
   [(register label capability-ref #:optional netlayer-name)
    (if netlayer-name
        ;; Register with OCapN to get sturdyref
        (on (<- mycapn 'register capability-ref netlayer-name)
            (lambda (sref)
              (let ((uri (ocapn-id->string sref)))
                (hash-set! registry label (cons capability-ref uri))
                (hash-set! uri->label uri label)
                `((label . ,label)
                  (sturdyref . ,uri)))))
        ;; Just store locally without network registration
        (begin
          (hash-set! registry label (cons capability-ref #f))
          `((label . ,label)
            (sturdyref . #f))))]

   ;; Lookup a capability by label (returns actor ref or #f)
   [(lookup label)
    (let ((entry (hash-ref registry label #f)))
      (and entry (car entry)))]

   ;; Get sturdyref URI by label
   [(get-sturdyref label)
    (let ((entry (hash-ref registry label #f)))
      (and entry (cdr entry)))]

   ;; Enliven a sturdyref URI to get a live capability reference
   [(enliven uri)
    (<- mycapn 'enliven (string->ocapn-id uri))]

   ;; List all registered capabilities
   [(list-all)
    (hash-map->list
     (lambda (label entry)
       `((label . ,label)
         (sturdyref . ,(cdr entry))))
     registry)]

   ;; Get full info about a registered capability
   [(info label)
    (let ((entry (hash-ref registry label #f)))
      (if entry
          (let ((cap-ref (car entry))
                (sref (cdr entry)))
            (on (<- cap-ref 'info)
                (lambda (cap-info)
                  `((label . ,label)
                    (sturdyref . ,sref)
                    (capability . ,cap-info)))))
          #f))]

   ;; Import a sturdyref and register under a label
   [(import uri label)
    (on (<- mycapn 'enliven (string->ocapn-id uri))
        (lambda (remote-cap)
          (hash-set! registry label (cons remote-cap uri))
          (hash-set! uri->label uri label)
          `((label . ,label)
            (sturdyref . ,uri))))]

   ;; Unregister a capability
   [(unregister label)
    (let ((entry (hash-ref registry label #f)))
      (when entry
        (let ((uri (cdr entry)))
          (when uri
            (hash-remove! uri->label uri))
          (hash-remove! registry label))))]))

;;; --------------------------------------------------------------------
;;; Convenience Functions
;;; --------------------------------------------------------------------

(define* (make-sturdyref-for-capability mycapn capability netlayer-name)
  "Register a capability with OCapN and return its sturdyref URI string.

   MYCAPN: the ^mycapn coordinator
   CAPABILITY: the capability actor reference (e.g., ^graph-facet)
   NETLAYER-NAME: symbol naming the netlayer ('onion, 'tcp-tls, etc.)

   Returns a promise that resolves to the sturdyref URI string."
  (on (<- mycapn 'register capability netlayer-name)
      (lambda (sref)
        (ocapn-id->string sref))))

(define (enliven-sturdyref mycapn uri)
  "Enliven a sturdyref URI to get a live capability reference.

   MYCAPN: the ^mycapn coordinator
   URI: sturdyref URI string

   Returns a promise that resolves to the live actor reference."
  (<- mycapn 'enliven (string->ocapn-id uri)))

;;; --------------------------------------------------------------------
;;; Example Usage
;;; --------------------------------------------------------------------
;;;
;;; ;; === SERVER SIDE ===
;;;
;;; ;; 1. Create vat and OCapN infrastructure
;;; (define vat (spawn-vat))
;;; (define mycapn
;;;   (with-vat vat
;;;     (define netlayer (spawn ^onion-netlayer))
;;;     (spawn-mycapn netlayer)))
;;;
;;; ;; 2. Create gatekeeper and capability
;;; (define gatekeeper (with-vat vat (spawn ^graph-gatekeeper store)))
;;; (define read-cap
;;;   (with-vat vat
;;;     (make-root-capability gatekeeper
;;;                           '("xm:graph/project/acme")
;;;                           '(read)
;;;                           #:label "Read-only acme access")))
;;;
;;; ;; 3. Register capability and get sturdyref
;;; (with-vat vat
;;;   (on (<- mycapn 'register read-cap 'onion)
;;;       (lambda (sref)
;;;         (format #t "Share this URI: ~a~%" (ocapn-id->string sref)))))
;;;
;;; ;; === CLIENT SIDE ===
;;;
;;; ;; 1. Create vat and OCapN infrastructure
;;; (define client-vat (spawn-vat))
;;; (define client-mycapn
;;;   (with-vat client-vat
;;;     (define netlayer (spawn ^onion-netlayer))
;;;     (spawn-mycapn netlayer)))
;;;
;;; ;; 2. Enliven the shared sturdyref
;;; (define remote-cap-vow
;;;   (with-vat client-vat
;;;     (<- client-mycapn 'enliven
;;;         (string->ocapn-id "ocapn://xyz...#swiss-num"))))
;;;
;;; ;; 3. Use the capability
;;; (with-vat client-vat
;;;   (on remote-cap-vow
;;;       (lambda (cap)
;;;         (on (<- cap 'query "SELECT ?s WHERE {?s a xm:Entity}")
;;;             (lambda (results)
;;;               (display results))))))
