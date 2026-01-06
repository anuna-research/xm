;;; xm/cli/cap.scm --- Capability commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements cap create/attenuate/revoke/list/inspect/export/import commands.
;;;
;;; CAPABILITY MODEL (per Spritely Goblins):
;;;
;;; In Goblins, capabilities ARE actor references. The CLI bridges this
;;; model with human usability by:
;;;
;;; 1. LABELS - Human-readable names mapped to capability actor refs
;;; 2. STURDYREFS - Persistent URIs for network sharing
;;; 3. REGISTRY - Maps labels to (actor-ref, sturdyref) pairs
;;;
;;; The registry is stored in Bloblin for persistence across restarts.
;;; Sturdyrefs can be exported/imported for sharing with remote agents.

(define-module (xm cli cap)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm capability)
  #:use-module (xm gatekeeper)
  #:export (handle-cap-command
            cmd-cap-create
            cmd-cap-attenuate
            cmd-cap-revoke
            cmd-cap-list
            cmd-cap-inspect
            cmd-cap-export
            cmd-cap-import))

;;; --------------------------------------------------------------------
;;; Capability Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-cap-command subcommand opts global-opts vat gatekeeper registry)
  "Dispatch capability subcommands.

   VAT: the Goblins vat for actor operations
   GATEKEEPER: the ^graph-gatekeeper actor
   REGISTRY: the ^capability-registry actor"
  (case subcommand
    ((create) (cmd-cap-create opts global-opts vat gatekeeper registry))
    ((attenuate) (cmd-cap-attenuate opts global-opts vat registry))
    ((revoke) (cmd-cap-revoke opts global-opts vat registry))
    ((list) (cmd-cap-list opts global-opts vat registry))
    ((inspect) (cmd-cap-inspect opts global-opts vat registry))
    ((export) (cmd-cap-export opts global-opts vat registry))
    ((import) (cmd-cap-import opts global-opts vat registry))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown cap subcommand: ~a" subcommand)
                   "Available: create, attenuate, revoke, list, inspect, export, import"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; cap create
;;; --------------------------------------------------------------------

(define (cmd-cap-create opts global-opts vat gatekeeper registry)
  "Create a new root capability.

   Creates a ^graph-facet actor that wraps the gatekeeper with specific
   access constraints. The facet IS the capability.

   Options:
   -l, --label TEXT: Human-readable label (required)
   -g, --graph URI: Named graph to grant access to (repeatable, required)
   --read: Grant read permission
   --write: Grant write permission
   --admin: Grant admin permission
   --expires DURATION: Expiration (e.g., 7d, 24h)"

  (let* ((label (or (assoc-ref opts "label")
                    (assoc-ref opts "l")))
         (graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (admin-perm (assoc-ref opts "admin"))
         (expires (assoc-ref opts "expires")))

    ;; Validate required options
    (unless label
      (output-error "MISSING_LABEL"
                    "A label is required"
                    "Use -l or --label to specify a human-readable name"
                    global-opts)
      (exit 2))

    (when (null? graphs)
      (output-error "MISSING_GRAPH"
                    "At least one graph is required"
                    "Use -g or --graph to specify graphs"
                    global-opts)
      (exit 2))

    ;; Build permissions list
    (let ((permissions (filter identity
                               (list (and read-perm 'read)
                                     (and write-perm 'write)
                                     (and admin-perm 'admin)))))

      ;; Default to read permission if none specified
      (when (null? permissions)
        (set! permissions '(read)))

      ;; Create capability within vat context
      (with-vat vat
        ;; Create the graph facet (THE CAPABILITY)
        (let* ((expires-time (and expires (parse-duration expires)))
               (capability
                (spawn ^graph-facet gatekeeper graphs permissions
                       #:expires expires-time
                       #:label label)))

          ;; Register with label in registry
          ($ registry 'register label capability)

          (let ((result `((label . ,label)
                          (graphs . ,graphs)
                          (permissions . ,permissions)
                          (expires . ,(and expires-time
                                           (time->iso8601 expires-time))))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                (begin
                  (format #t "\nCapability created: ~a\n" label)
                  (format #t "Graphs: ~a\n" (string-join graphs ", "))
                  (format #t "Permissions: ~a\n" permissions)
                  (when expires-time
                    (format #t "Expires: ~a\n" (time->iso8601 expires-time)))
                  (format #t "\nUse 'xm cap export ~a' to get a shareable URI\n" label)))))))))

;;; --------------------------------------------------------------------
;;; cap attenuate
;;; --------------------------------------------------------------------

(define (cmd-cap-attenuate opts global-opts vat registry)
  "Create an attenuated (weaker) capability from an existing one.

   In Goblins, attenuation spawns a new facet actor with stricter
   constraints. The new facet IS the attenuated capability.

   Usage: xm cap attenuate <PARENT_LABEL> --label <NEW_LABEL>
   Options:
   -l, --label TEXT: Label for new capability (required)
   -g, --graph URI: Limit to these graphs (must be subset)
   --read: Include read permission
   --write: Include write permission
   --expires DURATION: Shorten expiration"

  (let* ((positional (assoc-ref opts 'positional))
         (parent-label (and (pair? positional) (car positional)))
         (new-label (or (assoc-ref opts "label")
                        (assoc-ref opts "l")))
         (graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (expires (assoc-ref opts "expires")))

    (unless parent-label
      (output-error "MISSING_PARENT"
                    "Parent capability label is required"
                    "Usage: xm cap attenuate <PARENT_LABEL> --label <NEW_LABEL>"
                    global-opts)
      (exit 2))

    (unless new-label
      (output-error "MISSING_LABEL"
                    "A label for the new capability is required"
                    "Use -l or --label to specify a human-readable name"
                    global-opts)
      (exit 2))

    ;; Build permissions list (if any specified)
    (let ((permissions (filter identity
                               (list (and read-perm 'read)
                                     (and write-perm 'write)))))

      (with-vat vat
        ;; Look up parent capability
        (let ((parent-cap ($ registry 'lookup parent-label)))
          (unless parent-cap
            (output-error "CAP_NOT_FOUND"
                          (format #f "No capability named '~a'" parent-label)
                          "Use 'xm cap list' to see available capabilities"
                          global-opts)
            (exit 1))

          ;; Attenuate by calling the parent's attenuate method
          ;; This spawns a new facet with restricted access
          (let* ((expires-time (and expires (parse-duration expires)))
                 (attenuated-cap
                  ($ parent-cap 'attenuate
                     #:graphs (if (null? graphs) #f graphs)
                     #:ops (if (null? permissions) #f permissions)
                     #:new-expires expires-time
                     #:new-label new-label)))

            ;; Register the new capability
            ($ registry 'register new-label attenuated-cap)

            ;; Get info from the new capability
            (let* ((info ($ attenuated-cap 'info))
                   (result `((label . ,new-label)
                             (parent . ,parent-label)
                             (graphs . ,(assoc-ref info 'graphs))
                             (permissions . ,(assoc-ref info 'operations))
                             (expires . ,(assoc-ref info 'expires)))))

              (if (assoc-ref global-opts "json")
                  (output-result result global-opts)
                  (begin
                    (format #t "\nAttenuated capability created: ~a\n" new-label)
                    (format #t "Parent: ~a\n" parent-label)
                    (format #t "Graphs: ~a\n"
                            (string-join (assoc-ref info 'graphs) ", "))
                    (format #t "Permissions: ~a\n" (assoc-ref info 'operations))
                    (when (assoc-ref info 'expires)
                      (format #t "Expires: ~a\n" (assoc-ref info 'expires))))))))))))

;;; --------------------------------------------------------------------
;;; cap revoke
;;; --------------------------------------------------------------------

(define (cmd-cap-revoke opts global-opts vat registry)
  "Revoke a capability.

   Marks the capability as revoked in the registry. Note that for true
   revocation, the capability facet should have been created with a
   revoked-cell that can be set.

   Usage: xm cap revoke <LABEL>"

  (let* ((positional (assoc-ref opts 'positional))
         (label (and (pair? positional) (car positional))))

    (unless label
      (output-error "MISSING_LABEL"
                    "Capability label is required"
                    "Usage: xm cap revoke <LABEL>"
                    global-opts)
      (exit 2))

    (with-vat vat
      (if ($ registry 'exists? label)
          (begin
            ($ registry 'revoke label)
            (let ((result `((revoked . ,label))))
              (if (assoc-ref global-opts "json")
                  (output-result result global-opts)
                  (format #t "\nCapability revoked: ~a\n" label))))
          (begin
            (output-error "CAP_NOT_FOUND"
                          (format #f "No capability named '~a'" label)
                          "Use 'xm cap list' to see available capabilities"
                          global-opts)
            (exit 1))))))

;;; --------------------------------------------------------------------
;;; cap list
;;; --------------------------------------------------------------------

(define (cmd-cap-list opts global-opts vat registry)
  "List registered capabilities."

  (with-vat vat
    (let* ((include-revoked (assoc-ref opts "include-revoked"))
           (labels ($ registry 'list-all include-revoked))
           (capabilities
            (map (lambda (label)
                   (let ((info ($ registry 'info label)))
                     `((label . ,label)
                       (sturdyref . ,(assoc-ref info 'sturdyref))
                       (revoked . ,(assoc-ref info 'revoked)))))
                 labels)))

      (if (assoc-ref global-opts "json")
          (output-result `((capabilities . ,capabilities)
                           (count . ,(length capabilities)))
                         global-opts)
          (begin
            (format #t "\nCapabilities:\n\n")
            (if (null? capabilities)
                (format #t "  (no capabilities registered)\n")
                (for-each
                 (lambda (cap)
                   (format #t "  ~a~a\n"
                           (assoc-ref cap 'label)
                           (if (assoc-ref cap 'revoked) " [REVOKED]" "")))
                 capabilities)))))))

;;; --------------------------------------------------------------------
;;; cap inspect
;;; --------------------------------------------------------------------

(define (cmd-cap-inspect opts global-opts vat registry)
  "Inspect a capability's full details.

   Usage: xm cap inspect <LABEL>"

  (let* ((positional (assoc-ref opts 'positional))
         (label (and (pair? positional) (car positional))))

    (unless label
      (output-error "MISSING_LABEL"
                    "Capability label is required"
                    "Usage: xm cap inspect <LABEL>"
                    global-opts)
      (exit 2))

    (with-vat vat
      (let ((cap ($ registry 'lookup label)))
        (if (not cap)
            (begin
              (output-error "CAP_NOT_FOUND"
                            (format #f "No capability named '~a'" label)
                            "Use 'xm cap list' to see available capabilities"
                            global-opts)
              (exit 1))
            (let* ((info ($ cap 'info))
                   (sref ($ registry 'get-sturdyref label))
                   (result `((label . ,label)
                             (graphs . ,(assoc-ref info 'graphs))
                             (permissions . ,(assoc-ref info 'operations))
                             (expires . ,(assoc-ref info 'expires))
                             (sturdyref . ,sref))))

              (if (assoc-ref global-opts "json")
                  (output-result result global-opts)
                  (begin
                    (format #t "\nCapability: ~a\n\n" label)
                    (format #t "Graphs:\n")
                    (for-each (lambda (g) (format #t "  - ~a\n" g))
                              (assoc-ref info 'graphs))
                    (format #t "\nPermissions: ~a\n" (assoc-ref info 'operations))
                    (if (assoc-ref info 'expires)
                        (format #t "Expires: ~a\n" (assoc-ref info 'expires))
                        (format #t "Expires: never\n"))
                    (format #t "\nSturdyref: ~a\n"
                            (or sref "(not exported)")))))))))

;;; --------------------------------------------------------------------
;;; cap export
;;; --------------------------------------------------------------------

(define (cmd-cap-export opts global-opts vat registry mycapn)
  "Export a capability as a shareable sturdyref URI.

   Registers the capability with OCapN to get a network-accessible
   sturdyref that can be shared with remote agents.

   Usage: xm cap export <LABEL> [--netlayer NAME]
   Options:
   --netlayer NAME: Netlayer to use (onion, tcp-tls, etc.)"

  (let* ((positional (assoc-ref opts 'positional))
         (label (and (pair? positional) (car positional)))
         (netlayer (or (assoc-ref opts "netlayer") 'onion)))

    (unless label
      (output-error "MISSING_LABEL"
                    "Capability label is required"
                    "Usage: xm cap export <LABEL>"
                    global-opts)
      (exit 2))

    (with-vat vat
      (let ((cap ($ registry 'lookup label)))
        (if (not cap)
            (begin
              (output-error "CAP_NOT_FOUND"
                            (format #f "No capability named '~a'" label)
                            "Use 'xm cap list' to see available capabilities"
                            global-opts)
              (exit 1))
            ;; Register with OCapN to get sturdyref
            (on (<- mycapn 'register cap netlayer)
                (lambda (sref)
                  (let* ((uri (ocapn-id->string sref))
                         (result `((label . ,label)
                                   (sturdyref . ,uri)
                                   (netlayer . ,netlayer))))
                    ;; Store sturdyref in registry
                    ($ registry 'set-sturdyref label uri)

                    (if (assoc-ref global-opts "json")
                        (output-result result global-opts)
                        (begin
                          (format #t "\nCapability exported: ~a\n\n" label)
                          (format #t "Sturdyref URI:\n~a\n\n" uri)
                          (format #t "Share this URI with remote agents.\n")
                          (format #t "They can import it with:\n")
                          (format #t "  xm cap import '~a' --label <name>\n" uri)))))))))))

;;; --------------------------------------------------------------------
;;; cap import
;;; --------------------------------------------------------------------

(define (cmd-cap-import opts global-opts vat registry mycapn)
  "Import a capability from a sturdyref URI.

   Enlivens the sturdyref to get a live capability reference, then
   registers it with a local label.

   Usage: xm cap import <URI> --label <LABEL>"

  (let* ((positional (assoc-ref opts 'positional))
         (uri (and (pair? positional) (car positional)))
         (label (or (assoc-ref opts "label")
                    (assoc-ref opts "l"))))

    (unless uri
      (output-error "MISSING_URI"
                    "Sturdyref URI is required"
                    "Usage: xm cap import <URI> --label <LABEL>"
                    global-opts)
      (exit 2))

    (unless label
      (output-error "MISSING_LABEL"
                    "A label is required"
                    "Use -l or --label to specify a local name for this capability"
                    global-opts)
      (exit 2))

    (with-vat vat
      ;; Enliven the sturdyref to get live reference
      (on (<- mycapn 'enliven (string->ocapn-id uri))
          (lambda (remote-cap)
            ;; Register with label
            ($ registry 'register label remote-cap uri)

            ;; Get info from the remote capability
            (on (<- remote-cap 'info)
                (lambda (info)
                  (let ((result `((label . ,label)
                                  (sturdyref . ,uri)
                                  (graphs . ,(assoc-ref info 'graphs))
                                  (permissions . ,(assoc-ref info 'operations)))))

                    (if (assoc-ref global-opts "json")
                        (output-result result global-opts)
                        (begin
                          (format #t "\nCapability imported: ~a\n" label)
                          (format #t "Graphs: ~a\n"
                                  (string-join (assoc-ref info 'graphs) ", "))
                          (format #t "Permissions: ~a\n"
                                  (assoc-ref info 'operations))))))))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (time->iso8601 time)
  "Convert SRFI-19 time to ISO 8601 string."
  (date->string (time-utc->date time) "~Y-~m-~dT~H:~M:~SZ"))

(define (parse-duration duration-str)
  "Parse a duration string (7d, 24h, 30m) to SRFI-19 time."
  (let* ((len (string-length duration-str))
         (unit (string-ref duration-str (- len 1)))
         (value (string->number (substring duration-str 0 (- len 1))))
         (now (current-time time-utc))
         (seconds (case unit
                    ((#\d) (* value 86400))   ; days
                    ((#\h) (* value 3600))    ; hours
                    ((#\m) (* value 60))      ; minutes
                    ((#\s) value)             ; seconds
                    (else (* value 86400))))) ; default to days
    (add-duration now (make-time time-duration 0 seconds))))

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))

(define (string-join strs sep)
  "Join strings with separator."
  (if (null? strs)
      ""
      (let loop ((strs (cdr strs)) (acc (car strs)))
        (if (null? strs)
            acc
            (loop (cdr strs) (string-append acc sep (car strs)))))))

(define (filter pred lst)
  "Keep elements where PRED returns true."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (if (pred (car lst))
            (loop (cdr lst) (cons (car lst) acc))
            (loop (cdr lst) acc)))))

(define (identity x) x)

;;; Import OCapN utilities
(use-modules (goblins ocapn ids))
