;;; xm/cli/link.scm --- Link commands for CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Implements link create/get/list/delete commands per SPEC-029 Section 5.12.

(define-module (xm cli link)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-link-command
            cmd-link-create
            cmd-link-get
            cmd-link-list
            cmd-link-delete))

;;; --------------------------------------------------------------------
;;; Link Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-link-command subcommand opts global-opts store cap-ref)
  "Dispatch link subcommands."
  (case subcommand
    ((create) (cmd-link-create opts global-opts store cap-ref))
    ((get) (cmd-link-get opts global-opts store cap-ref))
    ((list) (cmd-link-list opts global-opts store cap-ref))
    ((delete) (cmd-link-delete opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown link subcommand: ~a" subcommand)
                   "Available: create, get, list, delete"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; link create
;;; --------------------------------------------------------------------

(define (cmd-link-create opts global-opts store cap-ref)
  "Create a link between two nodes.
   Options:
   --from URI: Source node (required)
   --to URI: Target node (required)
   --predicate PRED: Predicate URI (required)
   -p, --property KEY=VALUE: Link metadata (repeatable)
   -g, --graph URI: Target graph"

  (let* ((from-node (assoc-ref opts "from"))
         (to-node (assoc-ref opts "to"))
         (predicate (assoc-ref opts "predicate"))
         (properties (filter-map
                      (lambda (opt)
                        (and (member (car opt) '("property" "p"))
                             (parse-key-value (cdr opt))))
                      opts))
         (graph-uri (or (assoc-ref opts "graph")
                        (assoc-ref opts "g")
                        (public-graph-uri)))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    ;; Validate required options
    (unless from-node
      (output-error "MISSING_FROM"
                    "Source node is required"
                    "Use --from to specify the source node URI"
                    global-opts)
      (exit 2))

    (unless to-node
      (output-error "MISSING_TO"
                    "Target node is required"
                    "Use --to to specify the target node URI"
                    global-opts)
      (exit 2))

    (unless predicate
      (output-error "MISSING_PREDICATE"
                    "Predicate is required"
                    "Use --predicate to specify the relationship type"
                    global-opts)
      (exit 2))

    (if dry-run
        ;; Dry run - show what would be created
        (let ((preview `((would-create . ((from . ,from-node)
                                          (to . ,to-node)
                                          (predicate . ,predicate)
                                          (properties . ,properties)
                                          (graph . ,graph-uri))))))
          (output-result preview global-opts))

        ;; Actually create the link
        (let* ((link-id (xm-link-uri (generate-uuid)))
               (pred-uri (expand-uri predicate))
               (timestamp (current-iso-timestamp))
               (from-uri (expand-uri from-node))
               (to-uri (expand-uri to-node)))

          ;; Insert the direct triple: <from> <predicate> <to>
          (store-insert-quad store from-uri pred-uri to-uri #:graph graph-uri)

          ;; Create reified link node for metadata/provenance
          (store-insert-quad store link-id rdf:type xm:Link #:graph graph-uri)
          (store-insert-quad store link-id xm:from from-uri #:graph graph-uri)
          (store-insert-quad store link-id xm:predicate pred-uri #:graph graph-uri)
          (store-insert-quad store link-id xm:to to-uri #:graph graph-uri)
          (store-insert-quad store link-id dcterms:created timestamp #:graph graph-uri)

          ;; Insert link properties
          (for-each
           (lambda (prop)
             (let ((prop-uri (expand-uri (car prop)))
                   (prop-val (cdr prop)))
               (store-insert-quad store link-id prop-uri prop-val #:graph graph-uri)))
           properties)

          (let ((result `((id . ,link-id)
                          (from . ,from-uri)
                          (to . ,to-uri)
                          (predicate . ,pred-uri)
                          (created_at . ,timestamp)
                          (properties . ,properties))))
            (output-result result global-opts))))))

;;; --------------------------------------------------------------------
;;; link get
;;; --------------------------------------------------------------------

(define (cmd-link-get opts global-opts store cap-ref)
  "Get link metadata and provenance.
   Usage: xm link get <LINK_ID>"

  (let* ((positional (assoc-ref opts 'positional))
         (link-id (and (pair? positional) (car positional))))

    (unless link-id
      (output-error "MISSING_LINK_ID"
                    "Link ID is required"
                    "Usage: xm link get <LINK_ID>"
                    global-opts)
      (exit 2))

    ;; Expand URI if it's a prefixed form
    (let* ((full-uri (expand-uri link-id))
           (graph-uri (public-graph-uri))
           ;; Build SPARQL query for link metadata
           (sparql (format #f "PREFIX xm: <https://xm.dev/ns/v1#>
PREFIX dcterms: <http://purl.org/dc/terms/>
PREFIX prov: <http://www.w3.org/ns/prov#>
SELECT ?from ?predicate ?to ?created ?creator
FROM <~a>
WHERE {
  <~a> xm:from ?from ;
       xm:predicate ?predicate ;
       xm:to ?to .
  OPTIONAL { <~a> dcterms:created ?created }
  OPTIONAL { <~a> prov:wasAttributedTo ?creator }
}" graph-uri full-uri full-uri full-uri))
           ;; Query the store
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed)))

      (if (null? bindings)
          ;; Link not found
          (begin
            (output-error "NOT_FOUND"
                          (format #f "Link not found: ~a" full-uri)
                          "Check that the link ID is correct"
                          global-opts)
            1)
          ;; Extract link data from first binding
          (let* ((binding (car bindings))
                 (from-val (get-binding-value binding "from"))
                 (pred-val (get-binding-value binding "predicate"))
                 (to-val (get-binding-value binding "to"))
                 (created-val (get-binding-value binding "created"))
                 (result `((link . ((id . ,full-uri)
                                    (from . ,(or (compact-uri from-val) from-val))
                                    (to . ,(or (compact-uri to-val) to-val))
                                    (predicate . ,(or (compact-uri pred-val) pred-val))
                                    (created_at . ,(or created-val "unknown"))
                                    (properties . ()))))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                ;; Human-readable output
                (let ((link (assoc-ref result 'link)))
                  (format #t "\nLink: ~a\n" (assoc-ref link 'id))
                  (format #t "From: ~a\n" (assoc-ref link 'from))
                  (format #t "Predicate: ~a\n" (assoc-ref link 'predicate))
                  (format #t "To: ~a\n" (assoc-ref link 'to))
                  (format #t "Created: ~a\n" (assoc-ref link 'created_at)))))))))

;;; --------------------------------------------------------------------
;;; link list
;;; --------------------------------------------------------------------

(define (cmd-link-list opts global-opts store cap-ref)
  "List links filtered by node, predicate, or direction.
   Options:
   --node URI: Filter by connected node
   --predicate PRED: Filter by predicate
   --direction in|out|both: Filter by direction (default: both)
   --limit N: Maximum results (default: 50)"

  (let* ((node-filter (assoc-ref opts "node"))
         (predicate-filter (assoc-ref opts "predicate"))
         (direction (or (assoc-ref opts "direction") "both"))
         (limit (string->number (or (assoc-ref opts "limit") "50")))
         (graph-uri (public-graph-uri)))

    ;; Build SPARQL query with proper prefixes and FROM clause
    (let* ((prefix-decl "PREFIX xm: <https://xm.dev/ns/v1#>\n")
           (from-clause (format #f "FROM <~a>\n" graph-uri))
           (sparql
            (cond
             ;; Filter by node
             ((and node-filter (string=? direction "out"))
              (string-append prefix-decl
               (format #f "SELECT ?link ?predicate ?to\n~aWHERE {
  ?link xm:from <~a> ;
        xm:predicate ?predicate ;
        xm:to ?to .
} LIMIT ~a" from-clause (expand-uri node-filter) limit)))

             ((and node-filter (string=? direction "in"))
              (string-append prefix-decl
               (format #f "SELECT ?link ?from ?predicate\n~aWHERE {
  ?link xm:from ?from ;
        xm:predicate ?predicate ;
        xm:to <~a> .
} LIMIT ~a" from-clause (expand-uri node-filter) limit)))

             ((and node-filter)
              (string-append prefix-decl
               (format #f "SELECT ?link ?from ?predicate ?to\n~aWHERE {
  {
    ?link xm:from <~a> ;
          xm:predicate ?predicate ;
          xm:to ?to .
    BIND(<~a> AS ?from)
  } UNION {
    ?link xm:from ?from ;
          xm:predicate ?predicate ;
          xm:to <~a> .
    BIND(<~a> AS ?to)
  }
} LIMIT ~a" from-clause
  (expand-uri node-filter) (expand-uri node-filter)
  (expand-uri node-filter) (expand-uri node-filter) limit)))

             ;; Filter by predicate only
             (predicate-filter
              (string-append prefix-decl
               (format #f "SELECT ?link ?from ?to\n~aWHERE {
  ?link xm:from ?from ;
        xm:predicate <~a> ;
        xm:to ?to .
} LIMIT ~a" from-clause (expand-uri predicate-filter) limit)))

             ;; No filter - list all
             (else
              (string-append prefix-decl
               (format #f "SELECT ?link ?from ?predicate ?to\n~aWHERE {
  ?link xm:from ?from ;
        xm:predicate ?predicate ;
        xm:to ?to .
} LIMIT ~a" from-clause limit)))))
           ;; Query the store
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           ;; Convert bindings to result format
           (results (map
                     (lambda (binding)
                       (let ((link-val (get-binding-value binding "link"))
                             (from-val (get-binding-value binding "from"))
                             (pred-val (get-binding-value binding "predicate"))
                             (to-val (get-binding-value binding "to")))
                         `((id . ,(or (compact-uri link-val) link-val))
                           (from . ,(or (compact-uri from-val) from-val))
                           (predicate . ,(or (compact-uri pred-val) pred-val))
                           (to . ,(or (compact-uri to-val) to-val)))))
                     bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((links . ,results)
                           (count . ,(length results))
                           (filters . ((node . ,node-filter)
                                       (predicate . ,predicate-filter)
                                       (direction . ,direction))))
                         global-opts)
          ;; Human-readable output
          (begin
            (format #t "\nLinks")
            (when node-filter (format #t " for ~a" node-filter))
            (when predicate-filter (format #t " with predicate ~a" predicate-filter))
            (format #t ":\n\n")
            (if (null? results)
                (format #t "  (no links found)\n")
                (for-each
                 (lambda (link)
                   (format #t "  ~a -> ~a -> ~a\n"
                           (assoc-ref link 'from)
                           (assoc-ref link 'predicate)
                           (assoc-ref link 'to)))
                 results)))))))

;;; --------------------------------------------------------------------
;;; link delete
;;; --------------------------------------------------------------------

(define (cmd-link-delete opts global-opts store cap-ref)
  "Delete a link.
   Usage: xm link delete <LINK_ID>
   Options:
   -f, --force: Skip confirmation"

  (let* ((positional (assoc-ref opts 'positional))
         (link-id (and (pair? positional) (car positional)))
         (force (or (assoc-ref opts "force")
                    (assoc-ref opts "f")))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    (unless link-id
      (output-error "MISSING_LINK_ID"
                    "Link ID is required"
                    "Usage: xm link delete <LINK_ID>"
                    global-opts)
      (exit 2))

    (cond
     (dry-run
      (output-result `((would-delete . ,link-id))
                     global-opts))

     ((not force)
      ;; Interactive confirmation
      (if (assoc-ref global-opts "no-input")
          (begin
            (output-error "CONFIRMATION_REQUIRED"
                          "Deletion requires confirmation"
                          "Use --force to skip confirmation"
                          global-opts)
            (exit 1))
          (begin
            (format #t "Delete link ~a? [y/N] " link-id)
            (let ((input (read-line)))
              (if (member input '("y" "Y" "yes" "Yes" "YES"))
                  (do-delete-link link-id global-opts store cap-ref)
                  (begin
                    (format (current-error-port) "Aborted.\n")
                    (exit 1)))))))

     (else
      (do-delete-link link-id global-opts store cap-ref)))))

(define (do-delete-link link-id global-opts store cap-ref)
  "Actually delete the link."
  (let* ((full-uri (expand-uri link-id))
         ;; Delete all triples about this link
         (sparql (format #f "DELETE WHERE { <~a> ?p ?o }" full-uri)))
    (store-update store sparql)
    (let ((result `((deleted . ,full-uri))))
      (output-result result global-opts))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time as ISO 8601 string."
  (date->string (time-utc->date (current-time time-utc))
                "~Y-~m-~dT~H:~M:~SZ"))

;; generate-uuid is imported from (xm store)

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))

(define (public-graph-uri)
  "Get the public graph URI."
  (xm-graph-uri "public"))

;;; --------------------------------------------------------------------
;;; SPARQL JSON Result Parsing
;;; --------------------------------------------------------------------

(define (get-sparql-bindings json-obj)
  "Extract bindings from SPARQL JSON results.
   JSON-OBJ is the parsed JSON alist."
  (let ((results (assoc-ref json-obj "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (get-binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-obj (assoc-ref binding var-name)))
    (and var-obj (assoc-ref var-obj "value"))))

(define (compact-uri uri)
  "Compact a full URI to prefixed form if possible."
  (cond
   ((not uri) #f)
   ((string-prefix? xm-ns uri)
    (string-append "xm:" (substring uri (string-length xm-ns))))
   ((string-prefix? rdf-ns uri)
    (string-append "rdf:" (substring uri (string-length rdf-ns))))
   ((string-prefix? rdfs-ns uri)
    (string-append "rdfs:" (substring uri (string-length rdfs-ns))))
   (else uri)))
