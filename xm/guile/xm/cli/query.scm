;;; xm/cli/query.scm --- Query commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements query sparql/nodes/backlinks/path commands per SPEC-029 Section 5.13.

(define-module (xm cli query)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-query-command
            cmd-query-sparql
            cmd-query-nodes
            cmd-query-backlinks
            cmd-query-path))

;;; --------------------------------------------------------------------
;;; Query Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-query-command subcommand opts global-opts store cap-ref)
  "Dispatch query subcommands."
  (case subcommand
    ((sparql) (cmd-query-sparql opts global-opts store cap-ref))
    ((nodes) (cmd-query-nodes opts global-opts store cap-ref))
    ((backlinks) (cmd-query-backlinks opts global-opts store cap-ref))
    ((path) (cmd-query-path opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown query subcommand: ~a" subcommand)
                   "Available: sparql, nodes, backlinks, path"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; query sparql
;;; --------------------------------------------------------------------

(define (cmd-query-sparql opts global-opts store cap-ref)
  "Execute a SPARQL query.
   Options:
   --timeout DURATION: Query timeout
   -o, --output FORMAT: Output format for CONSTRUCT
   --allow-from: Allow FROM clauses in query (bypasses graph restriction)"

  (let* ((positional (assoc-ref opts 'positional))
         (sparql (cond
                  ((and (pair? positional)
                        (string=? (car positional) "-"))
                   ;; Read from stdin
                   (read-all-stdin))
                  ((pair? positional)
                   (car positional))
                  (else #f)))
         (output-format (or (assoc-ref opts "output")
                            (assoc-ref opts "o")
                            "json"))
         (allow-from (assoc-ref opts "allow-from"))
         (graph-uri (public-graph-uri)))

    (unless sparql
      (output-error "MISSING_QUERY"
                    "SPARQL query is required"
                    "Usage: xm query sparql <QUERY> or xm query sparql -"
                    global-opts)
      (exit 2))

    ;; Security: Check for FROM clause injection
    (when (and (not allow-from) (query-has-from-clause? sparql))
      (output-error "FROM_CLAUSE_FORBIDDEN"
                    "FROM and FROM NAMED clauses are not allowed"
                    "Queries are restricted to the current graph. Use --allow-from to bypass."
                    global-opts)
      (exit 2))

    ;; Execute query with standard prefixes and FROM clause
    (let* ((prefixed-sparql (inject-standard-prefixes sparql))
           (safe-sparql (if allow-from
                            prefixed-sparql
                            (inject-from-clause prefixed-sparql graph-uri)))
           (result (execute-sparql-query store safe-sparql global-opts)))
      (if (assoc-ref global-opts "json")
          ;; JSON output - SPARQL JSON Results format
          (begin
            (display result)
            (newline))
          ;; Human output - tabular format
          (display-sparql-results result)))))

(define from-clause-rx
  (make-regexp "\\bFROM\\s+(NAMED\\s+)?<" regexp/icase))

(define (query-has-from-clause? sparql)
  "Check if SPARQL query contains FROM or FROM NAMED clause."
  (regexp-exec from-clause-rx sparql))

(define prefix-rx
  (make-regexp "^\\s*PREFIX\\s" regexp/icase))

(define (query-has-prefixes? sparql)
  "Check if SPARQL query already has PREFIX declarations."
  (regexp-exec prefix-rx sparql))

(define *standard-prefixes*
  "PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX prov: <http://www.w3.org/ns/prov#>
PREFIX dcterms: <http://purl.org/dc/terms/>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX xm: <https://xm.dev/ns/v1#>
")

(define (inject-standard-prefixes sparql)
  "Inject standard PREFIX declarations into SPARQL query if not already present.
   Only injects if the query doesn't already have PREFIX declarations."
  (if (query-has-prefixes? sparql)
      sparql
      (string-append *standard-prefixes* sparql)))

(define select-rx
  (make-regexp "\\bSELECT\\b" regexp/icase))

(define where-rx
  (make-regexp "\\bWHERE\\s*\\{" regexp/icase))

(define (inject-from-clause sparql graph-uri)
  "Inject FROM clause into SPARQL query before WHERE clause.
   Only works for SELECT queries."
  (let ((select-match (regexp-exec select-rx sparql))
        (where-match (regexp-exec where-rx sparql)))
    (cond
     ;; Both SELECT and WHERE found - inject FROM before WHERE
     ((and select-match where-match)
      (let ((where-start (match:start where-match)))
        (string-append
         (substring sparql 0 where-start)
         (format #f "FROM <~a>\n" graph-uri)
         (substring sparql where-start))))
     ;; SELECT but no WHERE (unusual but possible) - append FROM at end
     (select-match
      (string-append sparql (format #f "\nFROM <~a>" graph-uri)))
     ;; Not a SELECT query (CONSTRUCT, ASK, DESCRIBE) - return as-is
     (else sparql))))

(define (execute-sparql-query store sparql global-opts)
  "Execute SPARQL and return JSON results."
  (catch #t
    (lambda ()
      (store-query store sparql))
    (lambda (key . args)
      (if (assoc-ref global-opts "debug")
          (format (current-error-port) "Query error: ~a ~a~%Query: ~a~%"
                  key args sparql))
      "{\"head\":{\"vars\":[]},\"results\":{\"bindings\":[]}}")))

(define (display-sparql-results json-results)
  "Display SPARQL results in human-readable tabular format."
  (let* ((parsed (json-string->scm json-results))
         (head (assoc-ref parsed "head"))
         (vars (and head (assoc-ref head "vars")))
         (results (assoc-ref parsed "results"))
         (bindings (and results (assoc-ref results "bindings"))))
    (cond
     ((or (not bindings) (null? bindings) (not vars) (null? vars))
      (display "No results.\n"))
     (else
      ;; Print header
      (for-each (lambda (v) (format #t "~a\t" v)) vars)
      (newline)
      (for-each (lambda (v) (format #t "~a\t" (make-string (string-length v) #\-))) vars)
      (newline)
      ;; Print rows
      (for-each
       (lambda (binding)
         (for-each
          (lambda (var)
            (let ((val (assoc-ref binding var)))
              (format #t "~a\t"
                      (if val
                          (compact-uri (assoc-ref val "value"))
                          ""))))
          vars)
         (newline))
       bindings)))))

;;; --------------------------------------------------------------------
;;; query nodes
;;; --------------------------------------------------------------------

(define (cmd-query-nodes opts global-opts store cap-ref)
  "Search for nodes matching criteria.
   Options:
   -t, --type TYPE: Filter by node type
   -p, --property KEY=VALUE: Filter by property
   --has-link PRED:TARGET: Filter by outgoing link
   --since DURATION: Only recent nodes
   -l, --limit N: Maximum results"

  (let* ((node-type (or (assoc-ref opts "type")
                        (assoc-ref opts "t")))
         (properties (filter-map
                      (lambda (opt)
                        (and (member (car opt) '("property" "p"))
                             (parse-key-value (cdr opt))))
                      opts))
         (has-link (assoc-ref opts "has-link"))
         (since (assoc-ref opts "since"))
         (limit (or (assoc-ref opts "limit")
                    (assoc-ref opts "l")
                    "100"))
         (graph-uri (public-graph-uri)))

    ;; Build SPARQL query from filters
    (let* ((sparql (build-nodes-query node-type properties has-link since limit graph-uri))
           ;; Execute query
           (json-result (execute-sparql-query store sparql global-opts))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (results (map
                     (lambda (binding)
                       (let ((node-val (get-binding-value binding "node"))
                             (type-val (get-binding-value binding "type")))
                         `((id . ,(compact-uri node-val))
                           (type . ,(compact-uri type-val)))))
                     bindings)))

      (if (assoc-ref global-opts "json")
          ;; NDJSON output
          (for-each
           (lambda (node)
             (display (scm->json-string node))
             (newline))
           results)
          ;; Human output
          (begin
            (format #t "Found ~a nodes:\n\n" (length results))
            (if (null? results)
                (format #t "  (no nodes found)\n")
                (for-each
                 (lambda (node)
                   (format #t "  ~a (~a)\n"
                           (assoc-ref node 'id)
                           (assoc-ref node 'type)))
                 results)))))))

(define (build-nodes-query type properties has-link since limit graph-uri)
  "Build a SPARQL query from node search filters."
  (string-append
   "SELECT DISTINCT ?node ?type\n"
   (format #f "FROM <~a>\n" graph-uri)
   "WHERE {\n"
   "  ?node a ?type .\n"
   (if type
       (format #f "  FILTER(?type = <~a>)\n" (xm-node-type-uri (string->symbol type)))
       "")
   ;; Add property filters
   (apply string-append
          (map (lambda (prop)
                 (format #f "  ?node <~a> \"~a\" .\n"
                         (expand-uri (car prop))
                         (cdr prop)))
               properties))
   "}\n"
   (format #f "LIMIT ~a" limit)))

;;; --------------------------------------------------------------------
;;; query backlinks
;;; --------------------------------------------------------------------

(define (cmd-query-backlinks opts global-opts store cap-ref)
  "Find all nodes linking TO a target (Org-roam style).
   Options:
   -p, --predicate PRED: Filter by predicate
   -l, --limit N: Maximum results"

  (let* ((positional (assoc-ref opts 'positional))
         (node-id (and (pair? positional) (car positional)))
         (predicate (or (assoc-ref opts "predicate")
                        (assoc-ref opts "p")))
         (limit (or (assoc-ref opts "limit")
                    (assoc-ref opts "l")
                    "100"))
         (graph-uri (public-graph-uri)))

    (unless node-id
      (output-error "MISSING_NODE_ID"
                    "Target node ID is required"
                    "Usage: xm query backlinks <NODE_ID>"
                    global-opts)
      (exit 2))

    ;; Expand URI
    (let* ((full-uri (expand-uri node-id))
           ;; Build backlinks query
           (sparql (format #f "SELECT ?source ?predicate
FROM <~a>
WHERE {
  ?source ?predicate <~a> .
  ~a
}
LIMIT ~a" graph-uri full-uri
   (if predicate
       (format #f "FILTER(?predicate = <~a>)" (expand-uri predicate))
       "")
   limit))
           ;; Execute query
           (json-result (execute-sparql-query store sparql global-opts))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (results (map
                     (lambda (binding)
                       (let ((source-val (get-binding-value binding "source"))
                             (pred-val (get-binding-value binding "predicate")))
                         `((source . ,(compact-uri source-val))
                           (predicate . ,(compact-uri pred-val)))))
                     bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((target . ,(compact-uri full-uri))
                           (backlinks . ,results))
                         global-opts)
          (begin
            (format #t "Backlinks to ~a:\n\n" (compact-uri full-uri))
            (if (null? results)
                (display "  (no backlinks found)\n")
                (for-each
                 (lambda (bl)
                   (format #t "  <- ~a <- ~a\n"
                           (assoc-ref bl 'predicate)
                           (assoc-ref bl 'source)))
                 results)))))))

;;; --------------------------------------------------------------------
;;; query path
;;; --------------------------------------------------------------------

(define (cmd-query-path opts global-opts store cap-ref)
  "Find paths between nodes.
   Options:
   -f, --from SOURCE: Starting node (required)
   -t, --to TARGET: Ending node (required)
   --max-hops N: Maximum path length
   --predicate PRED: Only follow specific predicates"

  (let* ((from-node (or (assoc-ref opts "from")
                        (assoc-ref opts "f")))
         (to-node (or (assoc-ref opts "to")
                      (assoc-ref opts "t")))
         (max-hops (string->number
                    (or (assoc-ref opts "max-hops") "5")))
         (predicate (assoc-ref opts "predicate"))
         (graph-uri (public-graph-uri)))

    (unless from-node
      (output-error "MISSING_FROM"
                    "Starting node is required"
                    "Use -f or --from to specify"
                    global-opts)
      (exit 2))

    (unless to-node
      (output-error "MISSING_TO"
                    "Ending node is required"
                    "Use -t or --to to specify"
                    global-opts)
      (exit 2))

    ;; Path finding via SPARQL property paths
    ;; Note: This is a simplified check for direct connection
    ;; Full path finding would require recursive queries
    (let* ((from-uri (expand-uri from-node))
           (to-uri (expand-uri to-node))
           (sparql (build-path-query from-uri to-uri max-hops predicate graph-uri))
           ;; Execute query
           (json-result (execute-sparql-query store sparql global-opts))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (paths (if (null? bindings)
                      '()
                      (list `((steps . ,(map (lambda (b)
                                               (compact-uri (get-binding-value b "predicate")))
                                             bindings)))))))

      (if (assoc-ref global-opts "json")
          (output-result `((from . ,(compact-uri from-uri))
                           (to . ,(compact-uri to-uri))
                           (paths . ,paths))
                         global-opts)
          (begin
            (format #t "Paths from ~a to ~a:\n\n" from-node to-node)
            (if (null? paths)
                (display "  (no paths found)\n")
                (for-each display-path paths)))))))

(define (build-path-query from to max-hops predicate graph-uri)
  "Build SPARQL for path finding.
   For now, this checks for direct connection only."
  ;; Simplified: just check if there's any direct link
  (format #f "SELECT ?predicate
FROM <~a>
WHERE {
  <~a> ?predicate <~a> .
}
LIMIT 1" graph-uri from to))

(define (display-path path)
  "Display a path in human-readable format."
  (format #t "  Path:\n")
  (for-each
   (lambda (step)
     (format #t "    ~a\n" step))
   path))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (read-all-stdin)
  "Read all content from stdin."
  (let loop ((lines '()))
    (let ((line (read-line)))
      (if (eof-object? line)
          (string-join (reverse lines) "\n")
          (loop (cons line lines))))))

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
  "Extract bindings from SPARQL JSON results."
  (let ((results (assoc-ref json-obj "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (get-binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-obj (assoc-ref binding var-name)))
    (and var-obj (assoc-ref var-obj "value"))))

;;; --------------------------------------------------------------------
;;; JSON Output
;;; --------------------------------------------------------------------

(define (scm->json-string obj)
  "Convert Scheme object to JSON string."
  (cond
   ((null? obj) "{}")
   ((pair? obj)
    (if (and (pair? (car obj)) (symbol? (caar obj)))
        ;; Alist -> JSON object
        (string-append "{"
                       (string-join
                        (map (lambda (pair)
                               (format #f "\"~a\":~a"
                                       (symbol->string (car pair))
                                       (scm->json-string (cdr pair))))
                             obj)
                        ",")
                       "}")
        ;; List -> JSON array
        (string-append "["
                       (string-join (map scm->json-string obj) ",")
                       "]")))
   ((string? obj) (format #f "\"~a\"" (escape-json-string obj)))
   ((number? obj) (number->string obj))
   ((boolean? obj) (if obj "true" "false"))
   ((symbol? obj) (format #f "\"~a\"" (symbol->string obj)))
   (else "\"\"")))

(define (escape-json-string str)
  "Escape special characters in JSON string."
  (let loop ((chars (string->list str)) (acc '()))
    (if (null? chars)
        (list->string (reverse acc))
        (let ((c (car chars)))
          (case c
            ((#\") (loop (cdr chars) (append '(#\" #\\) acc)))
            ((#\\) (loop (cdr chars) (append '(#\\ #\\) acc)))
            ((#\newline) (loop (cdr chars) (append '(#\n #\\) acc)))
            ((#\return) (loop (cdr chars) (append '(#\r #\\) acc)))
            ((#\tab) (loop (cdr chars) (append '(#\t #\\) acc)))
            (else (loop (cdr chars) (cons c acc))))))))
