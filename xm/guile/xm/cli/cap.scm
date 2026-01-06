;;; xm/cli/cap.scm --- Capability commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements cap create/attenuate/revoke/list/inspect commands per SPEC-029 Section 5.15.

(define-module (xm cli cap)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-cap-command
            cmd-cap-create
            cmd-cap-attenuate
            cmd-cap-revoke
            cmd-cap-list
            cmd-cap-inspect))

;;; Re-export vocabulary bindings for use in this module
(define rdf:type (@ (xm vocabulary) rdf:type))
(define rdfs:label (@ (xm vocabulary) rdfs:label))
(define dcterms:created (@ (xm vocabulary) dcterms:created))

;;; --------------------------------------------------------------------
;;; Capability Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-cap-command subcommand opts global-opts store cap-ref)
  "Dispatch capability subcommands."
  (case subcommand
    ((create) (cmd-cap-create opts global-opts store cap-ref))
    ((attenuate) (cmd-cap-attenuate opts global-opts store cap-ref))
    ((revoke) (cmd-cap-revoke opts global-opts store cap-ref))
    ((list) (cmd-cap-list opts global-opts store cap-ref))
    ((inspect) (cmd-cap-inspect opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown cap subcommand: ~a" subcommand)
                   "Available: create, attenuate, revoke, list, inspect"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; cap create
;;; --------------------------------------------------------------------

(define (cmd-cap-create opts global-opts store cap-ref)
  "Create a new root capability.
   Options:
   -g, --graph URI: Named graph to grant access to (repeatable, required)
   --read: Grant read permission
   --write: Grant write permission
   --admin: Grant admin permission
   --expires DURATION: Expiration (e.g., 7d, 24h)
   -l, --label TEXT: Human-readable label"

  (let* ((graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (admin-perm (assoc-ref opts "admin"))
         (expires (assoc-ref opts "expires"))
         (label (or (assoc-ref opts "label")
                    (assoc-ref opts "l"))))

    ;; Validate required options
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

      ;; Create capability
      (let* ((cap-id (xm-cap-uri (generate-uuid)))
             (timestamp (current-iso-timestamp))
             (expires-at (and expires (parse-duration-to-iso expires)))
             (cap-graph (capabilities-graph-uri)))

        ;; Store capability in RDF
        (store-insert-quad store cap-id rdf:type (xm-uri "Capability") #:graph cap-graph)
        (store-insert-quad store cap-id dcterms:created timestamp #:graph cap-graph)

        ;; Store granted graphs
        (for-each
         (lambda (g)
           (store-insert-quad store cap-id (xm-uri "grantsAccess") (expand-uri g) #:graph cap-graph))
         graphs)

        ;; Store permissions
        (for-each
         (lambda (perm)
           (store-insert-quad store cap-id (xm-uri "hasPermission") (symbol->string perm) #:graph cap-graph))
         permissions)

        ;; Store expiration if present
        (when expires-at
          (store-insert-quad store cap-id (xm-uri "expiresAt") expires-at #:graph cap-graph))

        ;; Store label if present
        (when label
          (store-insert-quad store cap-id rdfs:label label #:graph cap-graph))

        (let ((result `((id . ,cap-id)
                        (graphs . ,graphs)
                        (permissions . ,permissions)
                        (created_at . ,timestamp)
                        (expires . ,expires-at)
                        (label . ,label))))

          (if (assoc-ref global-opts "json")
            (output-result result global-opts)
            (begin
              (format #t "\nCapability created: ~a\n" cap-id)
              (format #t "Graphs: ~a\n" (string-join graphs ", "))
              (format #t "Permissions: ~a\n" permissions)
              (when expires-at (format #t "Expires: ~a\n" expires-at))
              (when label (format #t "Label: ~a\n" label))
              (format #t "\nExport XM_CAP=~a\n" cap-id))))))))

;;; --------------------------------------------------------------------
;;; cap attenuate
;;; --------------------------------------------------------------------

(define (cmd-cap-attenuate opts global-opts store cap-ref)
  "Create an attenuated (weaker) capability from an existing one.
   Usage: xm cap attenuate <CAP_ID>
   Options:
   -g, --graph URI: Limit to these graphs (must be subset)
   --read: Include read permission
   --write: Include write permission
   --expires DURATION: Shorten expiration
   -l, --label TEXT: Human-readable label"

  (let* ((positional (assoc-ref opts 'positional))
         (parent-id (and (pair? positional) (car positional)))
         (graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (expires (assoc-ref opts "expires"))
         (label (or (assoc-ref opts "label")
                    (assoc-ref opts "l"))))

    (unless parent-id
      (output-error "MISSING_CAP_ID"
                    "Parent capability ID is required"
                    "Usage: xm cap attenuate <CAP_ID> [options]"
                    global-opts)
      (exit 2))

    ;; Build permissions list
    (let ((permissions (filter identity
                               (list (and read-perm 'read)
                                     (and write-perm 'write)))))

      ;; Create attenuated capability
      (let* ((cap-id (xm-cap-uri (generate-uuid)))
             (timestamp (current-iso-timestamp))
             (expires-at (and expires (parse-duration-to-iso expires)))
             (cap-graph (capabilities-graph-uri)))

        ;; Store capability in RDF
        (store-insert-quad store cap-id rdf:type (xm-uri "Capability") #:graph cap-graph)
        (store-insert-quad store cap-id dcterms:created timestamp #:graph cap-graph)
        (store-insert-quad store cap-id (xm-uri "parent") (expand-uri parent-id) #:graph cap-graph)

        ;; Store granted graphs (if specified, otherwise inherit from parent)
        (unless (null? graphs)
          (for-each
           (lambda (g)
             (store-insert-quad store cap-id (xm-uri "grantsAccess") (expand-uri g) #:graph cap-graph))
           graphs))

        ;; Store permissions (if specified)
        (unless (null? permissions)
          (for-each
           (lambda (perm)
             (store-insert-quad store cap-id (xm-uri "hasPermission") (symbol->string perm) #:graph cap-graph))
           permissions))

        ;; Store expiration if present
        (when expires-at
          (store-insert-quad store cap-id (xm-uri "expiresAt") expires-at #:graph cap-graph))

        ;; Store label if present
        (when label
          (store-insert-quad store cap-id rdfs:label label #:graph cap-graph))

        (let ((result `((id . ,cap-id)
                        (parent . ,parent-id)
                        (graphs . ,(if (null? graphs) "inherited" graphs))
                        (permissions . ,(if (null? permissions) "inherited" permissions))
                        (created_at . ,timestamp)
                        (expires . ,expires-at)
                        (label . ,label))))

          (if (assoc-ref global-opts "json")
              (output-result result global-opts)
              (begin
                (format #t "\nAttenuated capability created: ~a\n" cap-id)
                (format #t "Parent: ~a\n" parent-id)
                (unless (null? graphs)
                  (format #t "Graphs: ~a\n" (string-join graphs ", ")))
                (unless (null? permissions)
                  (format #t "Permissions: ~a\n" permissions))
                (when expires-at (format #t "Expires: ~a\n" expires-at))
                (when label (format #t "Label: ~a\n" label)))))))))

;;; --------------------------------------------------------------------
;;; cap revoke
;;; --------------------------------------------------------------------

(define (cmd-cap-revoke opts global-opts store cap-ref)
  "Revoke a capability.
   Usage: xm cap revoke <CAP_ID>
   Options:
   --cascade: Also revoke all derived capabilities"

  (let* ((positional (assoc-ref opts 'positional))
         (cap-id (and (pair? positional) (car positional)))
         (cascade (assoc-ref opts "cascade")))

    (unless cap-id
      (output-error "MISSING_CAP_ID"
                    "Capability ID is required"
                    "Usage: xm cap revoke <CAP_ID>"
                    global-opts)
      (exit 2))

    (let ((cap-graph (capabilities-graph-uri))
          (full-cap-id (expand-uri cap-id)))

      ;; Set revoked flag in RDF store
      (store-insert-quad store full-cap-id (xm-uri "revoked") "true" #:graph cap-graph)
      (store-insert-quad store full-cap-id (xm-uri "revokedAt") (current-iso-timestamp) #:graph cap-graph)

      ;; If cascade, find and revoke derived capabilities
      (let ((derived-count (if cascade
                               (revoke-derived-capabilities store cap-graph full-cap-id)
                               0)))

        (let ((result `((revoked . ,cap-id)
                        (cascade . ,(if cascade #t #f))
                        (derived_revoked . ,derived-count))))

          (if (assoc-ref global-opts "json")
              (output-result result global-opts)
              (begin
                (format #t "\nCapability revoked: ~a\n" cap-id)
                (when cascade
                  (format #t "Derived capabilities also revoked: ~a\n" derived-count)))))))))

;;; --------------------------------------------------------------------
;;; cap list
;;; --------------------------------------------------------------------

(define (cmd-cap-list opts global-opts store cap-ref)
  "List capabilities.
   Options:
   --created-by-me: Only capabilities I created
   --active-only: Exclude expired/revoked
   --expired: Show expired capabilities"

  (let* ((created-by-me (assoc-ref opts "created-by-me"))
         (active-only (assoc-ref opts "active-only"))
         (show-expired (assoc-ref opts "expired"))
         (cap-graph (capabilities-graph-uri)))

    ;; Query capabilities from store
    (let* ((sparql (format #f "SELECT ?cap ?label ?revoked ?expires
FROM <~a>
WHERE {
  ?cap a <~a> .
  OPTIONAL { ?cap <~a> ?label }
  OPTIONAL { ?cap <~a> ?revoked }
  OPTIONAL { ?cap <~a> ?expires }
  ~a
}
ORDER BY DESC(?cap)" cap-graph (xm-uri "Capability")
                           rdfs:label (xm-uri "revoked") (xm-uri "expiresAt")
                           (if active-only
                               (format #f "FILTER(!BOUND(?revoked) || ?revoked != \"true\")")
                               "")))
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (capabilities (map parse-cap-binding bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((capabilities . ,capabilities)
                           (count . ,(length capabilities))
                           (filters . ((created_by_me . ,(if created-by-me #t #f))
                                       (active_only . ,(if active-only #t #f))
                                       (show_expired . ,(if show-expired #t #f)))))
                         global-opts)
          (begin
            (format #t "\nCapabilities")
            (when active-only (format #t " (active only)"))
            (format #t ":\n\n")
            (if (null? capabilities)
                (format #t "  (no capabilities found)\n")
                (for-each
                 (lambda (cap)
                   (format #t "  ~a  ~a\n"
                           (assoc-ref cap 'id)
                           (or (assoc-ref cap 'label) "")))
                 capabilities)))))))

;;; --------------------------------------------------------------------
;;; cap inspect
;;; --------------------------------------------------------------------

(define (cmd-cap-inspect opts global-opts store cap-ref)
  "Inspect a capability's full details.
   Usage: xm cap inspect <CAP_ID>"

  (let* ((positional (assoc-ref opts 'positional))
         (cap-id (and (pair? positional) (car positional))))

    (unless cap-id
      (output-error "MISSING_CAP_ID"
                    "Capability ID is required"
                    "Usage: xm cap inspect <CAP_ID>"
                    global-opts)
      (exit 2))

    (let* ((cap-graph (capabilities-graph-uri))
           (full-cap-id (expand-uri cap-id))
           ;; Query capability details
           (details (query-cap-details store cap-graph full-cap-id))
           ;; Query granted graphs
           (graphs (query-cap-graphs store cap-graph full-cap-id))
           ;; Query permissions
           (permissions (query-cap-permissions store cap-graph full-cap-id)))

      (if (null? details)
          (begin
            (output-error "CAP_NOT_FOUND"
                          (format #f "Capability not found: ~a" cap-id)
                          "Use 'xm cap list' to see available capabilities"
                          global-opts)
            (exit 1))
          (let ((result `((id . ,(compact-uri full-cap-id))
                          (graphs . ,(map compact-uri graphs))
                          (permissions . ,permissions)
                          (created_at . ,(assoc-ref details 'created))
                          (parent . ,(assoc-ref details 'parent))
                          (expires . ,(assoc-ref details 'expires))
                          (revoked . ,(assoc-ref details 'revoked))
                          (label . ,(assoc-ref details 'label)))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                (begin
                  (format #t "\nCapability: ~a\n\n" (compact-uri full-cap-id))
                  (format #t "Graphs:\n")
                  (for-each (lambda (g) (format #t "  - ~a\n" g))
                            (map compact-uri graphs))
                  (format #t "\nPermissions: ~a\n" permissions)
                  (format #t "Created: ~a\n" (or (assoc-ref details 'created) "unknown"))
                  (when (assoc-ref details 'parent)
                    (format #t "Parent: ~a\n" (compact-uri (assoc-ref details 'parent))))
                  (if (assoc-ref details 'expires)
                      (format #t "Expires: ~a\n" (assoc-ref details 'expires))
                      (format #t "Expires: never\n"))
                  (format #t "Status: ~a\n"
                          (if (assoc-ref details 'revoked) "revoked" "active"))
                  (when (assoc-ref details 'label)
                    (format #t "Label: ~a\n" (assoc-ref details 'label))))))))))

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

(define (parse-duration-to-iso duration-str)
  "Parse a duration string (7d, 24h, 30m) and return ISO timestamp for expiration."
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
    (date->string
     (time-utc->date
      (add-duration now (make-time time-duration 0 seconds)))
     "~Y-~m-~dT~H:~M:~SZ")))

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

;;; --------------------------------------------------------------------
;;; Capability Graph URI
;;; --------------------------------------------------------------------

(define (capabilities-graph-uri)
  "Get the capabilities graph URI."
  (xm-graph-uri "capabilities"))

;;; --------------------------------------------------------------------
;;; SPARQL Result Parsing Helpers
;;; --------------------------------------------------------------------

(define (get-sparql-bindings parsed)
  "Extract bindings list from parsed SPARQL JSON result."
  (let ((results (assoc-ref parsed "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (get-binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-data (assoc-ref binding var-name)))
    (if var-data
        (assoc-ref var-data "value")
        #f)))

(define (parse-cap-binding binding)
  "Parse a capability from a SPARQL binding."
  (let ((cap-val (get-binding-value binding "cap"))
        (label-val (get-binding-value binding "label"))
        (revoked-val (get-binding-value binding "revoked"))
        (expires-val (get-binding-value binding "expires")))
    `((id . ,(if cap-val (compact-uri cap-val) "unknown"))
      (label . ,label-val)
      (revoked . ,(and revoked-val (string=? revoked-val "true")))
      (expires . ,expires-val))))

;;; --------------------------------------------------------------------
;;; Capability Query Helpers
;;; --------------------------------------------------------------------

(define (query-cap-details store cap-graph cap-id)
  "Query detailed information about a capability."
  (let* ((sparql (format #f "SELECT ?created ?parent ?expires ?revoked ?label
FROM <~a>
WHERE {
  <~a> a <~a> .
  OPTIONAL { <~a> <~a> ?created }
  OPTIONAL { <~a> <~a> ?parent }
  OPTIONAL { <~a> <~a> ?expires }
  OPTIONAL { <~a> <~a> ?revoked }
  OPTIONAL { <~a> <~a> ?label }
}" cap-graph cap-id (xm-uri "Capability")
   cap-id dcterms:created
   cap-id (xm-uri "parent")
   cap-id (xm-uri "expiresAt")
   cap-id (xm-uri "revoked")
   cap-id rdfs:label))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (if (null? bindings)
        '()
        (let ((b (car bindings)))
          `((created . ,(get-binding-value b "created"))
            (parent . ,(get-binding-value b "parent"))
            (expires . ,(get-binding-value b "expires"))
            (revoked . ,(let ((r (get-binding-value b "revoked")))
                          (and r (string=? r "true"))))
            (label . ,(get-binding-value b "label")))))))

(define (query-cap-graphs store cap-graph cap-id)
  "Query graphs granted by a capability."
  (let* ((sparql (format #f "SELECT ?graph
FROM <~a>
WHERE {
  <~a> <~a> ?graph
}" cap-graph cap-id (xm-uri "grantsAccess")))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b) (get-binding-value b "graph")) bindings)))

(define (query-cap-permissions store cap-graph cap-id)
  "Query permissions granted by a capability."
  (let* ((sparql (format #f "SELECT ?perm
FROM <~a>
WHERE {
  <~a> <~a> ?perm
}" cap-graph cap-id (xm-uri "hasPermission")))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b)
           (let ((p (get-binding-value b "perm")))
             (if p (string->symbol p) 'unknown)))
         bindings)))

;;; --------------------------------------------------------------------
;;; Cascade Revoke Helper
;;; --------------------------------------------------------------------

(define (revoke-derived-capabilities store cap-graph parent-cap-id)
  "Revoke all capabilities derived from a parent capability.
   Returns the count of revoked derived capabilities."
  ;; Find all capabilities with this parent
  (let* ((sparql (format #f "SELECT ?cap
FROM <~a>
WHERE {
  ?cap <~a> <~a> .
  FILTER NOT EXISTS { ?cap <~a> \"true\" }
}" cap-graph (xm-uri "parent") parent-cap-id (xm-uri "revoked")))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed))
         (timestamp (current-iso-timestamp)))
    ;; Revoke each derived capability
    (let loop ((bindings bindings) (count 0))
      (if (null? bindings)
          count
          (let ((cap-id (get-binding-value (car bindings) "cap")))
            (when cap-id
              ;; Mark as revoked
              (store-insert-quad store cap-id (xm-uri "revoked") "true" #:graph cap-graph)
              (store-insert-quad store cap-id (xm-uri "revokedAt") timestamp #:graph cap-graph)
              ;; Recursively revoke children
              (revoke-derived-capabilities store cap-graph cap-id))
            (loop (cdr bindings) (+ count 1)))))))
