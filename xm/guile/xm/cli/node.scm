;;; xm/cli/node.scm --- Node commands for CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Implements node create/get/update/delete commands per SPEC-029 Section 5.11.

(define-module (xm cli node)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 ports)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-node-command
            cmd-node-create
            cmd-node-get
            cmd-node-update
            cmd-node-delete))

;;; --------------------------------------------------------------------
;;; Node Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-node-command subcommand opts global-opts store cap-ref)
  "Dispatch node subcommands."
  (case subcommand
    ((create) (cmd-node-create opts global-opts store cap-ref))
    ((get) (cmd-node-get opts global-opts store cap-ref))
    ((update) (cmd-node-update opts global-opts store cap-ref))
    ((delete) (cmd-node-delete opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown node subcommand: ~a" subcommand)
                   "Available: create, get, update, delete"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; node create
;;; --------------------------------------------------------------------

(define (cmd-node-create opts global-opts store cap-ref)
  "Create a new knowledge node.
   Options:
   -t, --type TYPE: Node type (required)
   -p, --property KEY=VALUE: Set property (repeatable)
   -l, --link PRED:TARGET: Create link (repeatable)
   -g, --graph URI: Target graph"

  (let* ((node-type (or (assoc-ref opts "type")
                        (assoc-ref opts "t")))
         (properties (filter-map
                      (lambda (opt)
                        (and (member (car opt) '("property" "p"))
                             (parse-key-value (cdr opt))))
                      opts))
         (links (filter-map
                 (lambda (opt)
                   (and (member (car opt) '("link" "l"))
                        (parse-link-spec (cdr opt))))
                 opts))
         (graph-uri (or (assoc-ref opts "graph")
                        (assoc-ref opts "g")
                        (public-graph-uri)))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    ;; Validate required options
    (unless node-type
      (output-error "MISSING_TYPE"
                    "Node type is required"
                    "Use -t or --type to specify: entity, fact, session, agent, artifact"
                    global-opts)
      (exit 2))

    ;; Validate node type
    (unless (member (string->symbol node-type)
                    '(entity fact session agent artifact))
      (output-error "INVALID_TYPE"
                    (format #f "Invalid node type: ~a" node-type)
                    "Valid types: entity, fact, session, agent, artifact"
                    global-opts)
      (exit 2))

    (if dry-run
        ;; Dry run - show what would be created
        (let ((preview `((would-create . ((type . ,node-type)
                                          (properties . ,properties)
                                          (links . ,links)
                                          (graph . ,graph-uri))))))
          (output-result preview global-opts))

        ;; Actually create the node
        (let* ((node-id (xm-node-uri (generate-uuid)))
               (type-uri (xm-node-type-uri (string->symbol node-type)))
               (timestamp (current-iso-timestamp)))

          ;; Insert node type triple
          (store-insert-quad store node-id rdf:type type-uri #:graph graph-uri)

          ;; Insert created timestamp
          (store-insert-quad store node-id dcterms:created timestamp #:graph graph-uri)

          ;; Insert properties
          (for-each
           (lambda (prop)
             (let ((prop-uri (expand-uri (car prop)))
                   (prop-val (cdr prop)))
               (store-insert-quad store node-id prop-uri prop-val #:graph graph-uri)))
           properties)

          ;; Create links
          (for-each
           (lambda (link)
             (let ((pred-uri (car link))
                   (target-uri (cdr link)))
               (store-insert-quad store node-id pred-uri target-uri #:graph graph-uri)))
           links)

          (let ((result `((id . ,node-id)
                          (type . ,node-type)
                          (created_at . ,timestamp)
                          (properties . ,properties)
                          (links_created . ,(length links)))))
            (output-result result global-opts))))))

;;; --------------------------------------------------------------------
;;; node get
;;; --------------------------------------------------------------------

(define (cmd-node-get opts global-opts store cap-ref)
  "Retrieve a node with its properties and links.
   Options:
   --depth N: Include neighbors up to N hops
   -b, --include-backlinks: Include backlinks"

  (let* ((positional (assoc-ref opts 'positional))
         (node-id (and (pair? positional) (car positional)))
         (depth (or (assoc-ref opts "depth") "0"))
         (include-backlinks (or (assoc-ref opts "include-backlinks")
                                (assoc-ref opts "b"))))

    (unless node-id
      (output-error "MISSING_NODE_ID"
                    "Node ID is required"
                    "Usage: xm node get <NODE_ID>"
                    global-opts)
      (exit 2))

    ;; Expand URI if it's a prefixed form
    (let* ((full-uri (expand-uri node-id))
           (graph-uri (public-graph-uri))
           ;; Build SPARQL query with FROM clause for named graph
           (sparql (format #f "SELECT ?p ?o FROM <~a> WHERE { <~a> ?p ?o }" graph-uri full-uri))
           ;; Query the store
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           ;; Extract bindings
           (bindings (get-sparql-bindings parsed)))

      ;; Check if node exists (has any bindings)
      (if (null? bindings)
          ;; Node not found
          (begin
            (output-error "NODE_NOT_FOUND"
                          (format #f "Node not found: ~a" node-id)
                          "The specified node does not exist in the store"
                          global-opts)
            (exit 1))

          ;; Node exists - build and output result
          (let* ((node-type (find-binding-value bindings rdf:type "uri"))
                 (properties (extract-properties bindings))
                 (result `((node . ((id . ,full-uri)
                                    (type . ,(or (compact-uri node-type) "unknown"))
                                    (properties . ,properties)))
                           (links . ())
                           (backlinks . ()))))

            (if (assoc-ref global-opts "json")
                (output-result result global-opts)
                ;; Human-readable output
                (begin
                  (format #t "\nNode: ~a\n" full-uri)
                  (format #t "Type: ~a\n" (or (compact-uri node-type) "unknown"))
                  (format #t "\nProperties:\n")
                  (if (null? properties)
                      (format #t "  (none)\n")
                      (for-each
                       (lambda (p) (format #t "  ~a: ~a\n" (car p) (cdr p)))
                       properties)))))))))

;;; --------------------------------------------------------------------
;;; node update
;;; --------------------------------------------------------------------

(define (cmd-node-update opts global-opts store cap-ref)
  "Update node properties.
   Options:
   -p, --property KEY=VALUE: Set property
   -r, --remove KEY: Remove property"

  (let* ((positional (assoc-ref opts 'positional))
         (node-id (and (pair? positional) (car positional)))
         (set-props (filter-map
                     (lambda (opt)
                       (and (member (car opt) '("property" "p"))
                            (parse-key-value (cdr opt))))
                     opts))
         (remove-props (filter-map
                        (lambda (opt)
                          (and (member (car opt) '("remove" "r"))
                               (cdr opt)))
                        opts))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    (unless node-id
      (output-error "MISSING_NODE_ID"
                    "Node ID is required"
                    "Usage: xm node update <NODE_ID> [options]"
                    global-opts)
      (exit 2))

    (if dry-run
        (output-result `((would-update . ,node-id)
                         (set . ,set-props)
                         (remove . ,remove-props))
                       global-opts)
        ;; Build and execute SPARQL UPDATE
        (let ((result `((id . ,node-id)
                        (updated_at . ,(current-iso-timestamp))
                        (properties-set . ,(length set-props))
                        (properties-removed . ,(length remove-props)))))
          (output-result result global-opts)))))

;;; --------------------------------------------------------------------
;;; node delete
;;; --------------------------------------------------------------------

(define (cmd-node-delete opts global-opts store cap-ref)
  "Delete a node.
   Options:
   --cascade: Also delete orphaned links
   -f, --force: Skip confirmation"

  (let* ((positional (assoc-ref opts 'positional))
         (node-id (and (pair? positional) (car positional)))
         (cascade (assoc-ref opts "cascade"))
         (force (or (assoc-ref opts "force")
                    (assoc-ref opts "f")))
         (no-input (assoc-ref global-opts "no-input"))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    (unless node-id
      (output-error "MISSING_NODE_ID"
                    "Node ID is required"
                    "Usage: xm node delete <NODE_ID> [options]"
                    global-opts)
      (exit 2))

    (cond
     (dry-run
      (output-result `((would-delete . ,node-id)
                       (cascade . ,(if cascade #t #f)))
                     global-opts))

     ;; --force or --no-input: proceed without confirmation
     ((or force no-input)
      (do-delete-node node-id cascade global-opts store cap-ref))

     ;; Interactive mode: prompt for confirmation
     ((isatty? (current-input-port))
      (format #t "This will delete node ~a\n" node-id)
      (format #t "Type the node ID to confirm: ")
      (force-output)
      (let ((input (read-line)))
        (cond
         ((eof-object? input)
          (format (current-error-port) "\nAborted: no input received.\n")
          (exit 1))
         ((string=? input node-id)
          (do-delete-node node-id cascade global-opts store cap-ref))
         (else
          (format (current-error-port) "Confirmation failed. Aborting.\n")
          (exit 1)))))

     ;; Non-interactive without --force or --no-input: error
     (else
      (output-error "CONFIRMATION_REQUIRED"
                    "Deletion requires confirmation"
                    "Use --force or --no-input to skip confirmation in non-interactive mode"
                    global-opts)
      (exit 1)))))

(define (do-delete-node node-id cascade global-opts store cap-ref)
  "Actually delete the node."
  ;; Build and execute DELETE SPARQL
  (let* ((full-uri (expand-uri node-id))
         (sparql (format #f "DELETE WHERE { <~a> ?p ?o }" full-uri)))
    (store-update store sparql)
    (let ((result `((deleted . ,full-uri)
                    (orphaned_links . 0))))
      (output-result result global-opts))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time as ISO 8601 string."
  (date->string (time-utc->date (current-time time-utc))
                "~Y-~m-~dT~H:~M:~SZ"))

;; generate-uuid is imported from (xm store)

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

(define (find-binding-value bindings predicate value-type)
  "Find the value for a predicate in bindings."
  (let loop ((bindings bindings))
    (if (null? bindings)
        #f
        (let* ((binding (car bindings))
               (p-val (assoc-ref binding "p"))
               (o-val (assoc-ref binding "o")))
          (if (and p-val
                   (equal? (assoc-ref p-val "value") predicate))
              (assoc-ref o-val "value")
              (loop (cdr bindings)))))))

(define (extract-properties bindings)
  "Extract property key-value pairs from bindings, excluding type and system props."
  (filter-map
   (lambda (binding)
     (let* ((p-val (assoc-ref binding "p"))
            (o-val (assoc-ref binding "o"))
            (p-uri (and p-val (assoc-ref p-val "value")))
            (o-value (and o-val (assoc-ref o-val "value"))))
       ;; Skip rdf:type and dcterms:created
       (if (and p-uri o-value
                (not (string=? p-uri rdf:type))
                (not (string=? p-uri dcterms:created)))
           (cons (compact-uri p-uri) o-value)
           #f)))
   bindings))

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

(define (parse-link-spec spec)
  "Parse a link specification PRED:TARGET into (predicate . target)."
  (let ((colon-pos (string-index spec #\:)))
    (if colon-pos
        (cons (expand-uri (substring spec 0 colon-pos))
              (expand-uri (substring spec (+ colon-pos 1))))
        #f)))

(define (string-index str char)
  "Find index of CHAR in STR."
  (let loop ((i 0))
    (cond
     ((>= i (string-length str)) #f)
     ((char=? (string-ref str i) char) i)
     (else (loop (+ i 1))))))

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))

(define (generate-node-turtle node-id type-uri properties timestamp)
  "Generate Turtle RDF for a new node."
  (string-append
   (format #f "<~a> a <~a> ;\n" node-id type-uri)
   (format #f "  <~a> \"~a\"^^<~a> "
           dcterms:created timestamp
           (string-append xsd-ns "dateTime"))
   (apply string-append
          (map (lambda (prop)
                 (format #f ";\n  <~a> ~a "
                         (expand-uri (car prop))
                         (format-rdf-value (cdr prop))))
               properties))
   ".\n"))

(define (format-rdf-value val)
  "Format a value for RDF Turtle."
  (cond
   ((string? val) (format #f "\"~a\"" val))
   ((number? val) (format #f "~a" val))
   ((boolean? val) (if val "true" "false"))
   (else (format #f "\"~a\"" val))))

(define (public-graph-uri)
  "Get the public graph URI."
  (xm-graph-uri "public"))
