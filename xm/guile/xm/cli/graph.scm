;;; xm/cli/graph.scm --- Named graph management commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements graph list/create/drop/stats commands per SPEC-029 Section 5.15.
;;; Named graphs provide logical isolation of RDF data within the store.

(define-module (xm cli graph)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-graph-command
            cmd-graph-list
            cmd-graph-create
            cmd-graph-drop
            cmd-graph-stats))

;;; --------------------------------------------------------------------
;;; Graph Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-graph-command subcommand opts global-opts store cap-ref)
  "Dispatch graph subcommands."
  (case subcommand
    ((list) (cmd-graph-list opts global-opts store cap-ref))
    ((create) (cmd-graph-create opts global-opts store cap-ref))
    ((drop) (cmd-graph-drop opts global-opts store cap-ref))
    ((stats) (cmd-graph-stats opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown graph subcommand: ~a" subcommand)
                   "Available: list, create, drop, stats"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; graph list
;;; --------------------------------------------------------------------

(define (cmd-graph-list opts global-opts store cap-ref)
  "List all named graphs in the store.
   Options:
   -v, --verbose: Show triple counts for each graph"

  (let* ((verbose (or (assoc-ref opts "verbose")
                      (assoc-ref opts "v")))
         (graph-uris (store-list-graphs store))
         (graphs (if verbose
                     ;; Include counts for each graph
                     (map (lambda (uri)
                            `((uri . ,(compact-uri uri))
                              (triple_count . ,(store-graph-count store uri))))
                          graph-uris)
                     ;; Just URIs
                     (map (lambda (uri)
                            `((uri . ,(compact-uri uri))))
                          graph-uris))))

    (if (assoc-ref global-opts "json")
        (output-result `((ok . #t)
                         (data . ((graphs . ,graphs)
                                  (count . ,(length graphs)))))
                       global-opts)
        ;; Human-readable output
        (begin
          (format #t "\nNamed Graphs:\n\n")
          (if (null? graphs)
              (format #t "  (no named graphs found)\n")
              (if verbose
                  (begin
                    (format #t "  ~40a ~10a\n" "Graph URI" "Triples")
                    (format #t "  ~40a ~10a\n" (make-string 40 #\-) (make-string 10 #\-))
                    (for-each
                     (lambda (g)
                       (format #t "  ~40a ~10d\n"
                               (assoc-ref g 'uri)
                               (assoc-ref g 'triple_count)))
                     graphs))
                  (for-each
                   (lambda (g)
                     (format #t "  ~a\n" (assoc-ref g 'uri)))
                   graphs)))
          (format #t "\nTotal: ~a graph~a\n"
                  (length graphs)
                  (if (= 1 (length graphs)) "" "s"))))))

;;; --------------------------------------------------------------------
;;; graph create
;;; --------------------------------------------------------------------

(define (cmd-graph-create opts global-opts store cap-ref)
  "Create a new named graph.
   Usage: xm graph create <graph-uri>

   Creates an empty named graph. Graph URIs should use the pattern:
   xm:graph/<category>/<name>"

  (let* ((positional (assoc-ref opts 'positional))
         (graph-input (and (pair? positional) (car positional))))

    (unless graph-input
      (output-error "MISSING_GRAPH_URI"
                    "Graph URI is required"
                    "Usage: xm graph create <graph-uri>"
                    global-opts)
      (exit 2))

    (let ((graph-uri (expand-uri graph-input)))
      ;; Check if graph already exists
      (if (store-graph-exists? store graph-uri)
          (begin
            (output-error "GRAPH_EXISTS"
                          (format #f "Graph already exists: ~a" (compact-uri graph-uri))
                          "Use 'xm graph drop' to remove it first"
                          global-opts)
            (exit 1))
          (begin
            ;; Create the graph
            (store-create-graph store graph-uri)

            (if (assoc-ref global-opts "json")
                (output-result `((ok . #t)
                                 (data . ((graph . ,(compact-uri graph-uri))
                                          (created . #t))))
                               global-opts)
                (format #t "Created graph: ~a\n" (compact-uri graph-uri))))))))

;;; --------------------------------------------------------------------
;;; graph drop
;;; --------------------------------------------------------------------

(define (cmd-graph-drop opts global-opts store cap-ref)
  "Drop a named graph and all its triples.
   Usage: xm graph drop <graph-uri> [--force]

   Options:
   -f, --force: Skip confirmation prompt
   -n, --dry-run: Show what would be deleted without actually deleting"

  (let* ((positional (assoc-ref opts 'positional))
         (graph-input (and (pair? positional) (car positional)))
         (force (or (assoc-ref opts "force")
                    (assoc-ref opts "f")))
         (dry-run (or (assoc-ref opts "dry-run")
                      (assoc-ref opts "n"))))

    (unless graph-input
      (output-error "MISSING_GRAPH_URI"
                    "Graph URI is required"
                    "Usage: xm graph drop <graph-uri> [--force]"
                    global-opts)
      (exit 2))

    (let ((graph-uri (expand-uri graph-input)))
      ;; Check if graph exists
      (unless (store-graph-exists? store graph-uri)
        (output-error "GRAPH_NOT_FOUND"
                      (format #f "Graph not found: ~a" (compact-uri graph-uri))
                      "Use 'xm graph list' to see available graphs"
                      global-opts)
        (exit 1))

      ;; Get triple count before deletion
      (let ((triple-count (store-graph-count store graph-uri)))

        (if dry-run
            ;; Dry run - just show what would be deleted
            (if (assoc-ref global-opts "json")
                (output-result `((ok . #t)
                                 (data . ((graph . ,(compact-uri graph-uri))
                                          (triple_count . ,triple-count)
                                          (dry_run . #t)
                                          (would_delete . #t))))
                               global-opts)
                (format #t "Would drop graph: ~a (~a triples)\n"
                        (compact-uri graph-uri) triple-count))

            ;; Actual deletion
            (begin
              ;; Confirmation unless --force
              (unless (or force (assoc-ref global-opts "json"))
                (format #t "Drop graph ~a? (~a triples) [y/N] "
                        (compact-uri graph-uri) triple-count)
                (let ((response (read-line)))
                  (unless (and response
                               (member (string-downcase response) '("y" "yes")))
                    (format #t "Cancelled.\n")
                    (exit 0))))

              ;; Drop the graph
              (store-drop-graph store graph-uri)

              (if (assoc-ref global-opts "json")
                  (output-result `((ok . #t)
                                   (data . ((graph . ,(compact-uri graph-uri))
                                            (triples_deleted . ,triple-count)
                                            (dropped . #t))))
                                 global-opts)
                  (format #t "Dropped graph: ~a (~a triples deleted)\n"
                          (compact-uri graph-uri) triple-count))))))))

;;; --------------------------------------------------------------------
;;; graph stats
;;; --------------------------------------------------------------------

(define (cmd-graph-stats opts global-opts store cap-ref)
  "Show detailed statistics for a named graph.
   Usage: xm graph stats <graph-uri>"

  (let* ((positional (assoc-ref opts 'positional))
         (graph-input (and (pair? positional) (car positional))))

    (unless graph-input
      (output-error "MISSING_GRAPH_URI"
                    "Graph URI is required"
                    "Usage: xm graph stats <graph-uri>"
                    global-opts)
      (exit 2))

    (let ((graph-uri (expand-uri graph-input)))
      ;; Check if graph exists
      (unless (store-graph-exists? store graph-uri)
        (output-error "GRAPH_NOT_FOUND"
                      (format #f "Graph not found: ~a" (compact-uri graph-uri))
                      "Use 'xm graph list' to see available graphs"
                      global-opts)
        (exit 1))

      ;; Get basic counts using FFI
      (let* ((triple-count (store-graph-count store graph-uri))
             ;; Get detailed stats via SPARQL
             (subject-count (get-distinct-count store graph-uri "s"))
             (predicate-count (get-distinct-count store graph-uri "p"))
             (object-count (get-distinct-count store graph-uri "o"))
             ;; Get top classes
             (top-classes (get-top-classes store graph-uri 10))
             ;; Get top predicates
             (top-predicates (get-top-predicates store graph-uri 10))
             ;; Build stats
             (stats `((graph . ,(compact-uri graph-uri))
                      (triples . ,triple-count)
                      (subjects . ,subject-count)
                      (predicates . ,predicate-count)
                      (objects . ,object-count)
                      (top_classes . ,top-classes)
                      (top_predicates . ,top-predicates))))

        (if (assoc-ref global-opts "json")
            (output-result `((ok . #t)
                             (data . ,stats))
                           global-opts)
            ;; Human-readable output
            (display-graph-stats-human stats))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (get-distinct-count store graph-uri var-name)
  "Get count of distinct values for a variable in a graph."
  (let* ((sparql (format #f "SELECT (COUNT(DISTINCT ?~a) AS ?count)
WHERE { GRAPH <~a> { ?s ?p ?o } }" var-name graph-uri))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (if (null? bindings)
        0
        (let ((count-val (get-binding-value (car bindings) "count")))
          (if count-val
              (string->number count-val)
              0)))))

(define (get-top-classes store graph-uri limit)
  "Get top N classes by instance count in a graph."
  (let* ((sparql (format #f "SELECT ?type (COUNT(?s) AS ?count)
WHERE { GRAPH <~a> { ?s a ?type } }
GROUP BY ?type
ORDER BY DESC(?count)
LIMIT ~a" graph-uri limit))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (binding)
           (let ((type-val (get-binding-value binding "type"))
                 (count-val (get-binding-value binding "count")))
             `((uri . ,(if type-val (compact-uri type-val) "unknown"))
               (count . ,(if count-val (string->number count-val) 0)))))
         bindings)))

(define (get-top-predicates store graph-uri limit)
  "Get top N predicates by usage count in a graph."
  (let* ((sparql (format #f "SELECT ?p (COUNT(*) AS ?count)
WHERE { GRAPH <~a> { ?s ?p ?o } }
GROUP BY ?p
ORDER BY DESC(?count)
LIMIT ~a" graph-uri limit))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (binding)
           (let ((pred-val (get-binding-value binding "p"))
                 (count-val (get-binding-value binding "count")))
             `((uri . ,(if pred-val (compact-uri pred-val) "unknown"))
               (count . ,(if count-val (string->number count-val) 0)))))
         bindings)))

(define (display-graph-stats-human stats)
  "Display graph statistics in human-readable format."
  (format #t "\n=== Graph: ~a ===\n\n" (assoc-ref stats 'graph))
  (format #t "Counts:\n")
  (format #t "  Triples:    ~a\n" (assoc-ref stats 'triples))
  (format #t "  Subjects:   ~a\n" (assoc-ref stats 'subjects))
  (format #t "  Predicates: ~a\n" (assoc-ref stats 'predicates))
  (format #t "  Objects:    ~a\n" (assoc-ref stats 'objects))

  (let ((classes (assoc-ref stats 'top_classes)))
    (when (and classes (not (null? classes)))
      (format #t "\nTop Classes:\n")
      (for-each
       (lambda (cls)
         (format #t "  ~30a ~6d\n"
                 (assoc-ref cls 'uri)
                 (assoc-ref cls 'count)))
       classes)))

  (let ((predicates (assoc-ref stats 'top_predicates)))
    (when (and predicates (not (null? predicates)))
      (format #t "\nTop Predicates:\n")
      (for-each
       (lambda (pred)
         (format #t "  ~30a ~6d\n"
                 (assoc-ref pred 'uri)
                 (assoc-ref pred 'count)))
       predicates)))

  (newline))

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

;;; --------------------------------------------------------------------
;;; Read-line for confirmation prompts
;;; --------------------------------------------------------------------

(define (read-line)
  "Read a line from standard input."
  (let loop ((chars '()))
    (let ((c (read-char)))
      (cond
       ((eof-object? c)
        (if (null? chars) #f (list->string (reverse chars))))
       ((char=? c #\newline)
        (list->string (reverse chars)))
       (else
        (loop (cons c chars)))))))
