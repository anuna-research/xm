;;; xm/cli/cap.scm --- Capability commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements cap create/attenuate/revoke/list/inspect/export/import commands.
;;;
;;; CAPABILITY MODEL:
;;;
;;; For CLI usage, capability metadata is stored in the RDF store:
;;; - xm:cap/<uuid> a xm:Capability
;;; - xm:cap/<uuid> xm:label "human-name"
;;; - xm:cap/<uuid> xm:grantsAccessTo <graph-uri>
;;; - xm:cap/<uuid> xm:hasPermission "read"|"write"|"admin"
;;; - xm:cap/<uuid> xm:expires <datetime>
;;; - xm:cap/<uuid> xm:revoked true/false
;;; - xm:cap/<uuid> xm:parent <parent-cap-uri>
;;;
;;; For network sharing, capabilities should be exported as sturdyrefs
;;; via the xm daemon which runs a Goblins vat.

(define-module (xm cli cap)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module ((xm cli output) #:select (output-result output-error))
  #:use-module ((xm cli daemon) #:select (daemon-running? daemon-rpc))
  #:use-module (xm store)
  #:use-module (xm vocabulary)
  #:export (handle-cap-command))

;;; --------------------------------------------------------------------
;;; Capability Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-cap-command subcommand opts global-opts store cap-ref)
  "Dispatch capability subcommands."
  (case subcommand
    ((create) (cmd-cap-create opts global-opts store))
    ((attenuate) (cmd-cap-attenuate opts global-opts store))
    ((revoke) (cmd-cap-revoke opts global-opts store))
    ((list) (cmd-cap-list opts global-opts store))
    ((inspect) (cmd-cap-inspect opts global-opts store))
    ((export) (cmd-cap-export opts global-opts store))
    ((import) (cmd-cap-import opts global-opts store))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown cap subcommand: ~a" subcommand)
                   "Available: create, attenuate, revoke, list, inspect, export, import"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; cap create
;;; --------------------------------------------------------------------

(define (cmd-cap-create opts global-opts store)
  "Create a new capability."
  (let* ((label (or (assoc-ref opts "label")
                    (assoc-ref opts "l")))
         (graphs (filter-map-opts opts '("graph" "g")))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (admin-perm (assoc-ref opts "admin"))
         (expires-str (assoc-ref opts "expires")))

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
    (let* ((perms (filter identity
                          (list (and read-perm "read")
                                (and write-perm "write")
                                (and admin-perm "admin"))))
           (perms (if (null? perms) '("read") perms))
           (cap-id (generate-cap-id))
           (now (time->iso8601 (current-time time-utc)))
           (expires (and expires-str (time->iso8601 (parse-duration expires-str)))))

      ;; Store capability in RDF
      (store-insert-capability store cap-id label graphs perms expires now)

      (let ((result `((id . ,cap-id)
                      (label . ,label)
                      (graphs . ,graphs)
                      (permissions . ,perms)
                      (expires . ,expires)
                      (created . ,now))))

        (if (assoc-ref global-opts "json")
            (output-result result global-opts)
            (begin
              (format #t "\nCapability created: ~a\n" label)
              (format #t "ID: ~a\n" cap-id)
              (format #t "Graphs: ~a\n" (string-join graphs ", "))
              (format #t "Permissions: ~a\n" (string-join perms ", "))
              (when expires
                (format #t "Expires: ~a\n" expires))
              (format #t "\nUse 'xm cap export ~a' to share this capability\n" label)))))))

;;; --------------------------------------------------------------------
;;; cap list
;;; --------------------------------------------------------------------

(define (cmd-cap-list opts global-opts store)
  "List registered capabilities."
  (let* ((include-revoked (assoc-ref opts "include-revoked"))
         (caps (query-capabilities store include-revoked)))

    (if (assoc-ref global-opts "json")
        (output-result `((capabilities . ,caps)
                         (count . ,(length caps)))
                       global-opts)
        (begin
          (format #t "\nCapabilities:\n\n")
          (if (null? caps)
              (format #t "  (no capabilities registered)\n")
              (for-each
               (lambda (cap)
                 (format #t "  ~a  ~a~a\n"
                         (or (assoc-ref cap 'label) "(unlabeled)")
                         (assoc-ref cap 'id)
                         (if (assoc-ref cap 'revoked) " [REVOKED]" "")))
               caps))))))

;;; --------------------------------------------------------------------
;;; cap inspect
;;; --------------------------------------------------------------------

(define (cmd-cap-inspect opts global-opts store)
  "Inspect a capability's details."
  (let* ((positional (assoc-ref opts 'positional))
         (label-or-id (and (pair? positional) (car positional))))

    (unless label-or-id
      (output-error "MISSING_LABEL"
                    "Capability label or ID is required"
                    "Usage: xm cap inspect <LABEL|ID>"
                    global-opts)
      (exit 2))

    (let ((cap (query-capability-by-label-or-id store label-or-id)))
      (if (not cap)
          (begin
            (output-error "CAP_NOT_FOUND"
                          (format #f "No capability found: ~a" label-or-id)
                          "Use 'xm cap list' to see available capabilities"
                          global-opts)
            (exit 1))
          (if (assoc-ref global-opts "json")
              (output-result cap global-opts)
              (begin
                (format #t "\nCapability: ~a\n" (or (assoc-ref cap 'label) "(unlabeled)"))
                (format #t "ID: ~a\n" (assoc-ref cap 'id))
                (format #t "\nGraphs:\n")
                (for-each (lambda (g) (format #t "  - ~a\n" g))
                          (or (assoc-ref cap 'graphs) '()))
                (format #t "\nPermissions: ~a\n"
                        (string-join (or (assoc-ref cap 'permissions) '()) ", "))
                (format #t "Expires: ~a\n" (or (assoc-ref cap 'expires) "never"))
                (format #t "Revoked: ~a\n" (if (assoc-ref cap 'revoked) "yes" "no"))))))))

;;; --------------------------------------------------------------------
;;; cap attenuate
;;; --------------------------------------------------------------------

(define (cmd-cap-attenuate opts global-opts store)
  "Create an attenuated capability from an existing one."
  (let* ((positional (assoc-ref opts 'positional))
         (parent-label (and (pair? positional) (car positional)))
         (new-label (or (assoc-ref opts "label") (assoc-ref opts "l")))
         (graphs (filter-map-opts opts '("graph" "g")))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (expires-str (assoc-ref opts "expires")))

    (unless parent-label
      (output-error "MISSING_PARENT"
                    "Parent capability label is required"
                    "Usage: xm cap attenuate <PARENT> --label <NEW_LABEL>"
                    global-opts)
      (exit 2))

    (unless new-label
      (output-error "MISSING_LABEL"
                    "A label for the new capability is required"
                    "Use -l or --label to specify a name"
                    global-opts)
      (exit 2))

    (let ((parent (query-capability-by-label-or-id store parent-label)))
      (unless parent
        (output-error "CAP_NOT_FOUND"
                      (format #f "No capability found: ~a" parent-label)
                      "Use 'xm cap list' to see available capabilities"
                      global-opts)
        (exit 1))

      ;; Attenuate: new graphs must be subset, permissions must be subset
      (let* ((parent-graphs (or (assoc-ref parent 'graphs) '()))
             (parent-perms (or (assoc-ref parent 'permissions) '()))
             (new-graphs (if (null? graphs) parent-graphs
                             (filter (lambda (g) (member g parent-graphs)) graphs)))
             (req-perms (filter identity
                                (list (and read-perm "read")
                                      (and write-perm "write"))))
             (new-perms (if (null? req-perms) parent-perms
                            (filter (lambda (p) (member p parent-perms)) req-perms)))
             (cap-id (generate-cap-id))
             (now (time->iso8601 (current-time time-utc)))
             (expires (and expires-str (time->iso8601 (parse-duration expires-str)))))

        (store-insert-capability store cap-id new-label new-graphs new-perms
                                 expires now (assoc-ref parent 'id))

        (let ((result `((id . ,cap-id)
                        (label . ,new-label)
                        (parent . ,(assoc-ref parent 'id))
                        (graphs . ,new-graphs)
                        (permissions . ,new-perms)
                        (expires . ,expires))))
          (if (assoc-ref global-opts "json")
              (output-result result global-opts)
              (begin
                (format #t "\nAttenuated capability created: ~a\n" new-label)
                (format #t "ID: ~a\n" cap-id)
                (format #t "Parent: ~a\n" (assoc-ref parent 'id))
                (format #t "Graphs: ~a\n" (string-join new-graphs ", "))
                (format #t "Permissions: ~a\n" (string-join new-perms ", ")))))))))

;;; --------------------------------------------------------------------
;;; cap revoke
;;; --------------------------------------------------------------------

(define (cmd-cap-revoke opts global-opts store)
  "Revoke a capability."
  (let* ((positional (assoc-ref opts 'positional))
         (label-or-id (and (pair? positional) (car positional))))

    (unless label-or-id
      (output-error "MISSING_LABEL"
                    "Capability label or ID is required"
                    "Usage: xm cap revoke <LABEL|ID>"
                    global-opts)
      (exit 2))

    (let ((cap (query-capability-by-label-or-id store label-or-id)))
      (if (not cap)
          (begin
            (output-error "CAP_NOT_FOUND"
                          (format #f "No capability found: ~a" label-or-id)
                          "Use 'xm cap list' to see available capabilities"
                          global-opts)
            (exit 1))
          (begin
            (store-revoke-capability store (assoc-ref cap 'id))
            (if (assoc-ref global-opts "json")
                (output-result `((revoked . ,(assoc-ref cap 'id))) global-opts)
                (format #t "\nCapability revoked: ~a\n" (assoc-ref cap 'id))))))))

;;; --------------------------------------------------------------------
;;; cap export
;;; --------------------------------------------------------------------

(define (cmd-cap-export opts global-opts store)
  "Export a capability as a shareable token.
   If the daemon is running with OCapN, exports as a sturdyref URI.
   Otherwise falls back to a local token (only works same-store)."
  (let* ((positional (assoc-ref opts 'positional))
         (label-or-id (and (pair? positional) (car positional)))
         (use-ocapn (assoc-ref opts "ocapn")))  ; --ocapn flag

    (unless label-or-id
      (output-error "MISSING_LABEL"
                    "Capability label or ID is required"
                    "Usage: xm cap export <LABEL|ID>"
                    global-opts)
      (exit 2))

    (let ((cap (query-capability-by-label-or-id store label-or-id)))
      (if (not cap)
          (begin
            (output-error "CAP_NOT_FOUND"
                          (format #f "No capability found: ~a" label-or-id)
                          global-opts)
            (exit 1))

          ;; Try OCapN export if daemon is running or --ocapn flag
          (if (or use-ocapn (daemon-running?))
              (export-via-ocapn label-or-id cap global-opts)
              ;; Fall back to local token
              (export-local-token cap global-opts))))))

(define (export-via-ocapn label cap global-opts)
  "Export capability via OCapN daemon, returning sturdyref."
  (let ((response (daemon-rpc "cap-export"
                              `(("label" . ,label)))))
    (if (not response)
        (begin
          (output-error "DAEMON_NOT_RUNNING"
                        "Cannot connect to xm daemon"
                        "Start daemon with: xm daemon start"
                        global-opts)
          (exit 1))
        (let ((error (assoc-ref response "error"))
              (result (assoc-ref response "result")))
          (if error
              (begin
                (output-error "OCAPN_EXPORT_FAILED"
                              error
                              "Falling back to local token"
                              global-opts)
                ;; Fall back to local token
                (export-local-token cap global-opts))
              ;; Success - output sturdyref
              (let ((sturdyref (assoc-ref result "sturdyref")))
                (if sturdyref
                    (if (assoc-ref global-opts "json")
                        (output-result `((sturdyref . ,sturdyref)
                                         (id . ,(assoc-ref cap 'id))
                                         (type . "ocapn"))
                                       global-opts)
                        (begin
                          (format #t "\nCapability exported via OCapN: ~a\n\n"
                                  (or (assoc-ref cap 'label) (assoc-ref cap 'id)))
                          (format #t "Sturdyref:\n~a\n\n" sturdyref)
                          (format #t "Share this URI with other agents.\n")
                          (format #t "Import with: xm cap import '<sturdyref>' --label <name>\n")))
                    ;; No sturdyref in response, use local token
                    (export-local-token cap global-opts))))))))

(define (export-local-token cap global-opts)
  "Export capability as local token (same-store only)."
  (let ((token (generate-cap-token cap)))
    (if (assoc-ref global-opts "json")
        (output-result `((token . ,token)
                         (id . ,(assoc-ref cap 'id))
                         (type . "local"))
                       global-opts)
        (begin
          (format #t "\nCapability exported (local token): ~a\n\n" (assoc-ref cap 'id))
          (format #t "Token:\n~a\n\n" token)
          (format #t "⚠️  Local token - only works within same store.\n")
          (format #t "   For cross-agent sharing, start daemon: xm daemon start\n\n")
          (format #t "Import with: xm cap import '<token>' --label <name>\n")))))

;;; --------------------------------------------------------------------
;;; cap import
;;; --------------------------------------------------------------------

(define (cmd-cap-import opts global-opts store)
  "Import a capability from a token or sturdyref.
   Detects token type:
   - ocapn:// URI -> import via OCapN (requires daemon)
   - xmcap: local token -> import from same store"
  (let* ((positional (assoc-ref opts 'positional))
         (token-or-uri (and (pair? positional) (car positional)))
         (label (or (assoc-ref opts "label") (assoc-ref opts "l"))))

    (unless token-or-uri
      (output-error "MISSING_TOKEN"
                    "Capability token or sturdyref URI is required"
                    "Usage: xm cap import <TOKEN|STURDYREF> --label <LABEL>"
                    global-opts)
      (exit 2))

    (unless label
      (output-error "MISSING_LABEL"
                    "A label is required"
                    "Use -l or --label to specify a local name"
                    global-opts)
      (exit 2))

    ;; Detect token type
    (cond
     ;; OCapN sturdyref
     ((is-sturdyref? token-or-uri)
      (import-via-ocapn token-or-uri label global-opts store))

     ;; Local token
     ((string-prefix? "xmcap:" token-or-uri)
      (import-local-token token-or-uri label global-opts store))

     ;; Unknown format
     (else
      (output-error "INVALID_TOKEN"
                    "Unrecognized token format"
                    "Expected xmcap:... (local) or ocapn://... (network)"
                    global-opts)
      (exit 1)))))

(define (is-sturdyref? str)
  "Check if STR is an OCapN sturdyref URI."
  (or (string-prefix? "ocapn://" str)
      (string-prefix? "ocapn:" str)))

(define (import-via-ocapn uri label global-opts store)
  "Import capability via OCapN daemon."
  (if (not (daemon-running?))
      (begin
        (output-error "DAEMON_NOT_RUNNING"
                      "OCapN import requires xm daemon"
                      "Start daemon with: xm daemon start"
                      global-opts)
        (exit 1))

      (let ((response (daemon-rpc "cap-import"
                                  `(("uri" . ,uri)
                                    ("label" . ,label)))))
        (if (not response)
            (begin
              (output-error "DAEMON_ERROR"
                            "Failed to communicate with daemon"
                            #f
                            global-opts)
              (exit 1))

            (let ((error (assoc-ref response "error"))
                  (result (assoc-ref response "result")))
              (if error
                  (begin
                    (output-error "OCAPN_IMPORT_FAILED"
                                  error
                                  #f
                                  global-opts)
                    (exit 1))

                  ;; Success - create local capability record
                  ;; The daemon has enlivened the sturdyref, we store metadata
                  (let* ((cap-id (generate-cap-id))
                         (now (time->iso8601 (current-time time-utc))))
                    ;; Store as remote capability
                    (store-insert-remote-capability store cap-id label uri now)

                    (if (assoc-ref global-opts "json")
                        (output-result `((id . ,cap-id)
                                         (label . ,label)
                                         (sturdyref . ,uri)
                                         (type . "ocapn"))
                                       global-opts)
                        (begin
                          (format #t "\nCapability imported via OCapN: ~a\n" label)
                          (format #t "ID: ~a\n" cap-id)
                          (format #t "Remote: ~a\n" uri)
                          (format #t "\nUse --cap ~a with queries to access remote graph.\n" label))))))))))

(define (import-local-token token label global-opts store)
  "Import capability from local token."
  ;; Parse token to get original capability ID
  (let ((original-id (parse-cap-token token)))
    (if (not original-id)
        (begin
          (output-error "INVALID_TOKEN"
                        "Could not parse capability token"
                        "Ensure the token is complete and valid"
                        global-opts)
          (exit 1))
        ;; Look up the original capability to get its properties
        (let ((original-cap (query-capability-by-label-or-id store original-id)))
          (if (not original-cap)
              (begin
                (output-error "CAP_NOT_FOUND"
                              (format #f "Original capability not found: ~a" original-id)
                              "The capability may have been revoked or deleted"
                              global-opts)
                (exit 1))
              (let* ((cap-id (generate-cap-id))
                     (now (time->iso8601 (current-time time-utc)))
                     (graphs (or (assoc-ref original-cap 'graphs) '()))
                     (perms (or (assoc-ref original-cap 'permissions) '("read")))
                     (expires (assoc-ref original-cap 'expires)))
                (store-insert-capability store cap-id label graphs perms expires now original-id)
                (if (assoc-ref global-opts "json")
                    (output-result `((id . ,cap-id)
                                     (label . ,label)
                                     (graphs . ,graphs)
                                     (permissions . ,perms)
                                     (imported-from . ,original-id)
                                     (type . "local"))
                                   global-opts)
                    (begin
                      (format #t "\nCapability imported (local): ~a\n" label)
                      (format #t "ID: ~a\n" cap-id)
                      (format #t "Graphs: ~a\n" (string-join graphs ", "))
                      (format #t "Permissions: ~a\n" (string-join perms ", "))))))))))

(define (store-insert-remote-capability store id label sturdyref created)
  "Insert a remote capability reference into the store."
  (catch #t
    (lambda ()
      ;; Insert type triple
      (store-insert-quad store id rdf:type xm:Capability #:graph cap-graph-uri)
      ;; Insert label
      (store-insert-quad store id xm:label label #:graph cap-graph-uri)
      ;; Insert sturdyref as remote reference
      (store-insert-quad store id (expand-uri "xm:sturdyref") sturdyref #:graph cap-graph-uri)
      ;; Mark as remote
      (store-insert-quad store id (expand-uri "xm:isRemote") "true" #:graph cap-graph-uri)
      ;; Insert created timestamp
      (store-insert-quad store id xm:created created #:graph cap-graph-uri)
      ;; Persist changes
      (store-persist store))
    (lambda (key . args)
      (format (current-error-port) "Error storing remote capability: ~a ~a~%" key args))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (generate-cap-id)
  "Generate a unique capability ID."
  (let ((now (current-time time-utc)))
    (string-append "https://xm.dev/ns/v1#cap/"
                   (number->string (time-second now) 16)
                   "-"
                   (number->string (random 999999) 16))))

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
                    ((#\d) (* value 86400))
                    ((#\h) (* value 3600))
                    ((#\m) (* value 60))
                    ((#\s) value)
                    (else (* value 86400)))))
    (add-duration now (make-time time-duration 0 seconds))))

(define (filter-map-opts opts keys)
  "Extract values from opts where key is in keys."
  (filter-map (lambda (opt)
                (and (pair? opt)
                     (member (car opt) keys)
                     (cdr opt)))
              (if (list? opts) opts '())))

(define (filter-map proc lst)
  "Map proc over lst, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))

(define (string-join strs sep)
  "Join strings with separator."
  (if (null? strs) ""
      (let loop ((strs (cdr strs)) (acc (car strs)))
        (if (null? strs) acc
            (loop (cdr strs) (string-append acc sep (car strs)))))))

;;; JSON/SPARQL parsing helpers
;; json-string->scm is imported from (xm store)

(define (get-sparql-bindings json-obj)
  "Extract bindings from SPARQL JSON results."
  (let ((results (assoc-ref json-obj "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (get-binding-value binding var-name)
  "Get value from a SPARQL binding for a variable."
  (let ((var-obj (assoc-ref binding var-name)))
    (if var-obj
        (assoc-ref var-obj "value")
        #f)))

;;; --------------------------------------------------------------------
;;; Store Operations
;;; --------------------------------------------------------------------

;; Graph for storing capability metadata
(define cap-graph-uri (xm-graph-uri "capabilities"))

;; Capability predicates
(define xm:label (expand-uri "xm:label"))
(define xm:grantsAccessTo (expand-uri "xm:grantsAccessTo"))
(define xm:hasPermission (expand-uri "xm:hasPermission"))
(define xm:expires (expand-uri "xm:expires"))
(define xm:revoked (expand-uri "xm:revoked"))
(define xm:parent (expand-uri "xm:parent"))
(define xm:created (expand-uri "xm:created"))

(define (store-insert-capability store id label graphs perms expires created . parent)
  "Insert a capability into the store using store-insert-quad."
  (let ((parent-id (and (pair? parent) (car parent))))
    (catch #t
      (lambda ()
        ;; Insert type triple
        (store-insert-quad store id rdf:type xm:Capability #:graph cap-graph-uri)
        ;; Insert label
        (store-insert-quad store id xm:label label #:graph cap-graph-uri)
        ;; Insert graphs
        (for-each
         (lambda (g)
           (store-insert-quad store id xm:grantsAccessTo g #:graph cap-graph-uri))
         graphs)
        ;; Insert permissions
        (for-each
         (lambda (p)
           (store-insert-quad store id xm:hasPermission p #:graph cap-graph-uri))
         perms)
        ;; Insert expires if present
        (when expires
          (store-insert-quad store id xm:expires expires #:graph cap-graph-uri))
        ;; Insert created timestamp
        (store-insert-quad store id xm:created created #:graph cap-graph-uri)
        ;; Insert revoked=false
        (store-insert-quad store id xm:revoked "false" #:graph cap-graph-uri)
        ;; Insert parent if present
        (when parent-id
          (store-insert-quad store id xm:parent parent-id #:graph cap-graph-uri))
        ;; Persist changes
        (store-persist store))
      (lambda (key . args)
        (format (current-error-port) "Error storing capability: ~a ~a~%" key args)))))

(define (query-capabilities store include-revoked)
  "Query all capabilities from store."
  (let ((query (string-append
                "PREFIX xm: <https://xm.dev/ns/v1#> "
                "SELECT ?id ?label ?revoked "
                "FROM <" cap-graph-uri "> "
                "WHERE { "
                "?id a xm:Capability . "
                "OPTIONAL { ?id xm:label ?label } "
                "OPTIONAL { ?id xm:revoked ?revoked } "
                (if include-revoked "" "FILTER(!bound(?revoked) || ?revoked = \"false\") ")
                "}")))
    (catch #t
      (lambda ()
        (let* ((json-result (store-query store query))
               (parsed (json-string->scm json-result))
               (bindings (get-sparql-bindings parsed)))
          (map (lambda (row)
                 `((id . ,(get-binding-value row "id"))
                   (label . ,(get-binding-value row "label"))
                   (revoked . ,(equal? (get-binding-value row "revoked") "true"))))
               bindings)))
      (lambda (key . args)
        '()))))

(define (query-capability-by-label-or-id store label-or-id)
  "Query a capability by label or ID."
  ;; Check if this looks like a URI (contains :// or starts with xm:)
  (let* ((is-uri (or (string-contains label-or-id "://")
                     (string-prefix? "xm:" label-or-id)))
         (query (string-append
                 "PREFIX xm: <https://xm.dev/ns/v1#> "
                 "SELECT ?id ?label ?revoked ?expires "
                 "FROM <" cap-graph-uri "> "
                 "WHERE { "
                 "?id a xm:Capability . "
                 "OPTIONAL { ?id xm:label ?label } "
                 "OPTIONAL { ?id xm:revoked ?revoked } "
                 "OPTIONAL { ?id xm:expires ?expires } "
                 (if is-uri
                     (string-append "FILTER(?id = <" (expand-uri label-or-id) ">) ")
                     (string-append "FILTER(?label = \"" label-or-id "\") "))
                 "} LIMIT 1")))
    (catch #t
      (lambda ()
        (let* ((json-result (store-query store query))
               (parsed (json-string->scm json-result))
               (bindings (get-sparql-bindings parsed)))
          (and (pair? bindings)
               (let ((row (car bindings)))
                 (let ((cap-id (get-binding-value row "id")))
                   `((id . ,cap-id)
                     (label . ,(get-binding-value row "label"))
                     (revoked . ,(equal? (get-binding-value row "revoked") "true"))
                     (expires . ,(get-binding-value row "expires"))
                     (graphs . ,(query-capability-graphs store cap-id))
                     (permissions . ,(query-capability-permissions store cap-id))))))))
      (lambda (key . args)
        #f))))

(define (query-capability-graphs store cap-id)
  "Query graphs for a capability."
  (let ((query (string-append
                "PREFIX xm: <https://xm.dev/ns/v1#> "
                "SELECT ?graph "
                "FROM <" cap-graph-uri "> "
                "WHERE { <" cap-id "> xm:grantsAccessTo ?graph }")))
    (catch #t
      (lambda ()
        (let* ((json-result (store-query store query))
               (parsed (json-string->scm json-result))
               (bindings (get-sparql-bindings parsed)))
          (map (lambda (row) (get-binding-value row "graph"))
               bindings)))
      (lambda (key . args) '()))))

(define (query-capability-permissions store cap-id)
  "Query permissions for a capability."
  (let ((query (string-append
                "PREFIX xm: <https://xm.dev/ns/v1#> "
                "SELECT ?perm "
                "FROM <" cap-graph-uri "> "
                "WHERE { <" cap-id "> xm:hasPermission ?perm }")))
    (catch #t
      (lambda ()
        (let* ((json-result (store-query store query))
               (parsed (json-string->scm json-result))
               (bindings (get-sparql-bindings parsed)))
          (map (lambda (row) (get-binding-value row "perm"))
               bindings)))
      (lambda (key . args) '()))))

(define (store-revoke-capability store cap-id)
  "Mark a capability as revoked."
  ;; First delete the old revoked value
  (catch #t
    (lambda ()
      (store-delete-quad store cap-id xm:revoked "false" #:graph cap-graph-uri))
    (lambda (key . args) #f))
  ;; Insert revoked=true
  (store-insert-quad store cap-id xm:revoked "true" #:graph cap-graph-uri)
  ;; Persist changes
  (store-persist store))

(define (generate-cap-token cap)
  "Generate a shareable token from capability info."
  ;; Simple base64-like encoding of capability info
  (string-append "xmcap:" (assoc-ref cap 'id)))

(define (parse-cap-token token)
  "Parse a capability token, returning the original capability ID or #f."
  (if (string-prefix? "xmcap:" token)
      (substring token 6)
      #f))
