;;; xm/cli/schema.scm --- Schema introspection commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements schema classes/predicates/describe commands per SPEC-029 Section 5.14.
;;; Schema introspection enables LLM agents to discover available classes,
;;; predicates, and graph structure at runtime.

(define-module (xm cli schema)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-schema-command
            cmd-schema-classes
            cmd-schema-predicates
            cmd-schema-describe))

;;; --------------------------------------------------------------------
;;; Schema Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-schema-command subcommand opts global-opts store cap-ref)
  "Dispatch schema subcommands."
  (case subcommand
    ((classes) (cmd-schema-classes opts global-opts store cap-ref))
    ((predicates) (cmd-schema-predicates opts global-opts store cap-ref))
    ((describe) (cmd-schema-describe opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown schema subcommand: ~a" subcommand)
                   "Available: classes, predicates, describe"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; schema classes
;;; --------------------------------------------------------------------

(define (cmd-schema-classes opts global-opts store cap-ref)
  "List all RDF classes (node types) in use within accessible graphs.
   Options:
   -g, --graph URI: Limit to specific graph (repeatable)
   -l, --limit N: Maximum results (default: 100)"

  (let* ((graph-filters (filter-map
                         (lambda (opt)
                           (and (member (car opt) '("graph" "g"))
                                (expand-uri (cdr opt))))
                         opts))
         (limit (string->number (or (assoc-ref opts "limit")
                                    (assoc-ref opts "l")
                                    "100")))
         (graph-uri (if (null? graph-filters)
                        (public-graph-uri)
                        (car graph-filters))))

    ;; Build SPARQL query to count instances by type
    (let* ((sparql (build-classes-query graph-uri limit))
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (classes (map
                     (lambda (binding)
                       (let ((type-val (get-binding-value binding "type"))
                             (count-val (get-binding-value binding "count")))
                         `((uri . ,(compact-uri type-val))
                           (count . ,(if count-val
                                         (string->number count-val)
                                         0)))))
                     bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((ok . #t)
                           (data . ((graphs . ,(list (compact-uri graph-uri)))
                                    (classes . ,classes))))
                         global-opts)
          ;; Human-readable output
          (begin
            (format #t "\nClasses in ~a:\n\n" (compact-uri graph-uri))
            (if (null? classes)
                (format #t "  (no classes found)\n")
                (for-each
                 (lambda (cls)
                   (format #t "  ~30a ~6d nodes\n"
                           (assoc-ref cls 'uri)
                           (assoc-ref cls 'count)))
                 classes)))))))

(define (build-classes-query graph-uri limit)
  "Build SPARQL query to count instances by rdf:type."
  (format #f "SELECT ?type (COUNT(?s) AS ?count)
FROM <~a>
WHERE {
  ?s a ?type .
}
GROUP BY ?type
ORDER BY DESC(?count)
LIMIT ~a" graph-uri limit))

;;; --------------------------------------------------------------------
;;; schema predicates
;;; --------------------------------------------------------------------

(define (cmd-schema-predicates opts global-opts store cap-ref)
  "List all predicates in use with usage statistics.
   Options:
   -g, --graph URI: Limit to specific graph (repeatable)
   -l, --limit N: Maximum results (default: 100)"

  (let* ((graph-filters (filter-map
                         (lambda (opt)
                           (and (member (car opt) '("graph" "g"))
                                (expand-uri (cdr opt))))
                         opts))
         (limit (string->number (or (assoc-ref opts "limit")
                                    (assoc-ref opts "l")
                                    "100")))
         (graph-uri (if (null? graph-filters)
                        (public-graph-uri)
                        (car graph-filters))))

    ;; Build SPARQL query to count predicate usage
    (let* ((sparql (build-predicates-query graph-uri limit))
           (json-result (store-query store sparql))
           (parsed (json-string->scm json-result))
           (bindings (get-sparql-bindings parsed))
           (predicates (map
                        (lambda (binding)
                          (let ((pred-val (get-binding-value binding "predicate"))
                                (count-val (get-binding-value binding "count")))
                            `((uri . ,(compact-uri pred-val))
                              (count . ,(if count-val
                                            (string->number count-val)
                                            0)))))
                        bindings)))

      (if (assoc-ref global-opts "json")
          (output-result `((ok . #t)
                           (data . ((graphs . ,(list (compact-uri graph-uri)))
                                    (predicates . ,predicates))))
                         global-opts)
          ;; Human-readable output
          (begin
            (format #t "\nPredicates in ~a:\n\n" (compact-uri graph-uri))
            (format #t "  ~30a ~10a\n" "Predicate" "Count")
            (format #t "  ~30a ~10a\n"
                    (make-string 30 #\─)
                    (make-string 10 #\─))
            (if (null? predicates)
                (format #t "  (no predicates found)\n")
                (for-each
                 (lambda (pred)
                   (format #t "  ~30a ~10d\n"
                           (assoc-ref pred 'uri)
                           (assoc-ref pred 'count)))
                 predicates)))))))

(define (build-predicates-query graph-uri limit)
  "Build SPARQL query to count predicate usage."
  (format #f "SELECT ?predicate (COUNT(*) AS ?count)
FROM <~a>
WHERE {
  ?s ?predicate ?o .
}
GROUP BY ?predicate
ORDER BY DESC(?count)
LIMIT ~a" graph-uri limit))

;;; --------------------------------------------------------------------
;;; schema describe
;;; --------------------------------------------------------------------

(define (cmd-schema-describe opts global-opts store cap-ref)
  "Combined schema summary optimized for LLM agent context injection.
   Options:
   -g, --graph URI: Limit to specific graph (repeatable)
   -f, --format FORMAT: Output format: json (default), turtle, markdown"

  (let* ((graph-filters (filter-map
                         (lambda (opt)
                           (and (member (car opt) '("graph" "g"))
                                (expand-uri (cdr opt))))
                         opts))
         (output-format (or (assoc-ref opts "format")
                            (assoc-ref opts "f")
                            "human"))
         (graph-uri (if (null? graph-filters)
                        (public-graph-uri)
                        (car graph-filters))))

    ;; Get statistics
    (let* ((node-count (get-node-count store graph-uri))
           (link-count (get-link-count store graph-uri))
           ;; Get classes
           (classes-sparql (build-classes-query graph-uri 50))
           (classes-result (store-query store classes-sparql))
           (classes-parsed (json-string->scm classes-result))
           (classes-bindings (get-sparql-bindings classes-parsed))
           (classes (map
                     (lambda (binding)
                       (let ((type-val (get-binding-value binding "type"))
                             (count-val (get-binding-value binding "count")))
                         `((uri . ,(compact-uri type-val))
                           (label . ,(uri-label type-val))
                           (count . ,(if count-val
                                         (string->number count-val)
                                         0)))))
                     classes-bindings))
           ;; Get predicates
           (predicates-sparql (build-predicates-query graph-uri 50))
           (predicates-result (store-query store predicates-sparql))
           (predicates-parsed (json-string->scm predicates-result))
           (predicates-bindings (get-sparql-bindings predicates-parsed))
           (predicates (map
                        (lambda (binding)
                          (let ((pred-val (get-binding-value binding "predicate"))
                                (count-val (get-binding-value binding "count")))
                            `((uri . ,(compact-uri pred-val))
                              (label . ,(uri-label pred-val))
                              (count . ,(if count-val
                                            (string->number count-val)
                                            0)))))
                        predicates-bindings)))

      (cond
       ;; JSON output
       ((or (assoc-ref global-opts "json") (string=? output-format "json"))
        (output-result
         `((ok . #t)
           (data . ((graphs . ,(list (compact-uri graph-uri)))
                    (statistics . ((node_count . ,node-count)
                                   (link_count . ,link-count)))
                    (classes . ,classes)
                    (predicates . ,predicates)
                    (namespaces . ((xm . ,xm-ns)
                                   (prov . ,prov-ns)
                                   (dcterms . ,dcterms-ns)
                                   (skos . ,skos-ns)
                                   (rdfs . ,rdfs-ns)
                                   (rdf . ,rdf-ns))))))
         global-opts))

       ;; Markdown output
       ((string=? output-format "markdown")
        (display-schema-markdown graph-uri node-count link-count classes predicates))

       ;; Turtle output
       ((string=? output-format "turtle")
        (display-schema-turtle classes predicates))

       ;; Human output (default)
       (else
        (display-schema-human graph-uri node-count link-count classes predicates))))))

(define (get-node-count store graph-uri)
  "Count total nodes (subjects with rdf:type) in graph."
  (let* ((sparql (format #f "SELECT (COUNT(DISTINCT ?s) AS ?count)
FROM <~a>
WHERE { ?s a ?type }" graph-uri))
         (result (store-query store sparql))
         (parsed (json-string->scm result))
         (bindings (get-sparql-bindings parsed)))
    (if (null? bindings)
        0
        (let ((count-val (get-binding-value (car bindings) "count")))
          (if count-val (string->number count-val) 0)))))

(define (get-link-count store graph-uri)
  "Count total triples in graph."
  (let* ((sparql (format #f "SELECT (COUNT(*) AS ?count)
FROM <~a>
WHERE { ?s ?p ?o }" graph-uri))
         (result (store-query store sparql))
         (parsed (json-string->scm result))
         (bindings (get-sparql-bindings parsed)))
    (if (null? bindings)
        0
        (let ((count-val (get-binding-value (car bindings) "count")))
          (if count-val (string->number count-val) 0)))))

(define (display-schema-human graph-uri node-count link-count classes predicates)
  "Display schema in human-readable format."
  (format #t "\nSchema Summary\n")
  (format #t "══════════════\n\n")
  (format #t "Graph: ~a\n\n" (compact-uri graph-uri))
  (format #t "Statistics:\n")
  (format #t "  Nodes: ~a\n" node-count)
  (format #t "  Triples: ~a\n\n" link-count)
  (format #t "Classes (~a):\n" (length classes))
  (if (null? classes)
      (format #t "  (none)\n")
      (for-each
       (lambda (cls)
         (format #t "  • ~a (~a)\n"
                 (assoc-ref cls 'uri)
                 (assoc-ref cls 'count)))
       classes))
  (format #t "\nPredicates (~a):\n" (length predicates))
  (if (null? predicates)
      (format #t "  (none)\n")
      (for-each
       (lambda (pred)
         (format #t "  • ~a (~a)\n"
                 (assoc-ref pred 'uri)
                 (assoc-ref pred 'count)))
       predicates)))

(define (display-schema-markdown graph-uri node-count link-count classes predicates)
  "Display schema in Markdown format."
  (format #t "# Schema Summary\n\n")
  (format #t "**Graph:** `~a`\n\n" (compact-uri graph-uri))
  (format #t "## Statistics\n\n")
  (format #t "- Nodes: ~a\n" node-count)
  (format #t "- Triples: ~a\n\n" link-count)
  (format #t "## Classes\n\n")
  (format #t "| Class | Count |\n")
  (format #t "|-------|-------|\n")
  (for-each
   (lambda (cls)
     (format #t "| `~a` | ~a |\n"
             (assoc-ref cls 'uri)
             (assoc-ref cls 'count)))
   classes)
  (format #t "\n## Predicates\n\n")
  (format #t "| Predicate | Count |\n")
  (format #t "|-----------|-------|\n")
  (for-each
   (lambda (pred)
     (format #t "| `~a` | ~a |\n"
             (assoc-ref pred 'uri)
             (assoc-ref pred 'count)))
   predicates))

(define (display-schema-turtle classes predicates)
  "Display schema in Turtle format (RDFS-style)."
  (format #t "@prefix rdf: <~a> .\n" rdf-ns)
  (format #t "@prefix rdfs: <~a> .\n" rdfs-ns)
  (format #t "@prefix xm: <~a> .\n" xm-ns)
  (format #t "@prefix prov: <~a> .\n" prov-ns)
  (format #t "@prefix dcterms: <~a> .\n\n" dcterms-ns)

  (format #t "# Classes\n")
  (for-each
   (lambda (cls)
     (let ((uri (assoc-ref cls 'uri)))
       (format #t "~a a rdfs:Class ;\n" (expand-uri-for-turtle uri))
       (format #t "    rdfs:label \"~a\" .\n\n" (assoc-ref cls 'label))))
   classes)

  (format #t "# Properties\n")
  (for-each
   (lambda (pred)
     (let ((uri (assoc-ref pred 'uri)))
       (format #t "~a a rdf:Property ;\n" (expand-uri-for-turtle uri))
       (format #t "    rdfs:label \"~a\" .\n\n" (assoc-ref pred 'label))))
   predicates))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

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

(define (uri-label uri)
  "Extract a human-readable label from a URI."
  (cond
   ((not uri) "")
   ((string-prefix? "http" uri)
    (let ((hash-pos (string-rindex uri #\#))
          (slash-pos (string-rindex uri #\/)))
      (cond
       (hash-pos (substring uri (+ hash-pos 1)))
       (slash-pos (substring uri (+ slash-pos 1)))
       (else uri))))
   ((string-index uri #\:)
    (substring uri (+ (string-index uri #\:) 1)))
   (else uri)))

(define (expand-uri-for-turtle uri)
  "Expand URI for Turtle output, wrapping full URIs in angle brackets."
  (if (and uri (string-index uri #\:))
      (let ((prefix (substring uri 0 (string-index uri #\:))))
        (if (member prefix '("xm" "rdf" "rdfs" "prov" "dcterms" "skos" "xsd"))
            uri  ; Keep prefixed form
            (string-append "<" (expand-uri uri) ">")))
      (string-append "<" (or uri "") ">")))

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
   ((string-prefix? prov-ns uri)
    (string-append "prov:" (substring uri (string-length prov-ns))))
   ((string-prefix? dcterms-ns uri)
    (string-append "dcterms:" (substring uri (string-length dcterms-ns))))
   ((string-prefix? skos-ns uri)
    (string-append "skos:" (substring uri (string-length skos-ns))))
   ((string-prefix? xsd-ns uri)
    (string-append "xsd:" (substring uri (string-length xsd-ns))))
   (else uri)))

(define (string-rindex str char)
  "Find last index of CHAR in STR, or #f if not found."
  (let loop ((i (- (string-length str) 1)))
    (cond
     ((< i 0) #f)
     ((char=? (string-ref str i) char) i)
     (else (loop (- i 1))))))

(define (string-index str char)
  "Find first index of CHAR in STR, or #f if not found."
  (let loop ((i 0))
    (cond
     ((>= i (string-length str)) #f)
     ((char=? (string-ref str i) char) i)
     (else (loop (+ i 1))))))
