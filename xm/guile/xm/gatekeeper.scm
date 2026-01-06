;;; xm/gatekeeper.scm --- Graph Gatekeeper actor for capability-based access
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; The Graph Gatekeeper is the central security actor in xm.
;;; All Oxigraph access passes through here. It validates capabilities,
;;; rewrites SPARQL queries to scope to allowed graphs, and enforces
;;; read/write/admin permissions.
;;;
;;; From SPEC-029 Section 4.1:
;;; "All Oxigraph access passes through here"

(define-module (xm gatekeeper)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (xm store)
  #:use-module (xm capability)
  #:use-module (xm vocabulary)
  #:export (^graph-gatekeeper
            public-graph-uri))

;;; --------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------

;; The public graph is readable without any capability
(define public-graph-uri (xm-graph-uri "public"))

;;; --------------------------------------------------------------------
;;; SPARQL Query Rewriting
;;; --------------------------------------------------------------------

(define (rewrite-query-with-graphs sparql allowed-graphs)
  "Rewrite a SPARQL query to scope to allowed named graphs.
   Adds FROM <graph> clauses for SELECT/ASK/CONSTRUCT/DESCRIBE queries.
   For UPDATE queries, validates graph targets.

   Example:
   Input:  SELECT ?s ?p ?o WHERE { ?s ?p ?o }
   Output: SELECT ?s ?p ?o FROM <graph1> FROM <graph2> WHERE { ?s ?p ?o }"

  (let ((query-type (detect-query-type sparql)))
    (case query-type
      ((select ask construct describe)
       (add-from-clauses sparql allowed-graphs))
      ((insert delete)
       ;; UPDATE queries - validate graph targets in the query itself
       sparql)
      (else
       (error "Unknown query type" sparql)))))

(define (detect-query-type sparql)
  "Detect the type of SPARQL query."
  (let ((upper (string-upcase (string-trim sparql))))
    (cond
     ((string-prefix? "SELECT" upper) 'select)
     ((string-prefix? "ASK" upper) 'ask)
     ((string-prefix? "CONSTRUCT" upper) 'construct)
     ((string-prefix? "DESCRIBE" upper) 'describe)
     ((string-prefix? "INSERT" upper) 'insert)
     ((string-prefix? "DELETE" upper) 'delete)
     ((string-prefix? "WITH" upper) 'update)  ; WITH ... DELETE/INSERT
     (else 'unknown))))

(define (add-from-clauses sparql allowed-graphs)
  "Add FROM <graph> clauses to a read query.
   Inserts them after the query keyword (SELECT/ASK/etc) and before WHERE."

  ;; Build FROM clause string
  (define from-clauses
    (string-join
     (map (lambda (g) (format #f "FROM <~a>" g)) allowed-graphs)
     "\n"))

  ;; Find WHERE position and insert FROM clauses before it
  (let ((where-match (string-match "WHERE" (string-upcase sparql))))
    (if where-match
        (let ((where-pos (match:start where-match)))
          (string-append
           (substring sparql 0 where-pos)
           from-clauses
           "\n"
           (substring sparql where-pos)))
        ;; No WHERE clause - append FROM at end (for DESCRIBE without WHERE)
        (string-append sparql "\n" from-clauses))))

(define (extract-update-graphs sparql)
  "Extract graph URIs referenced in a SPARQL UPDATE query.
   Returns a list of graph URIs found in GRAPH <uri> patterns."
  (let ((matches (list-matches "GRAPH\\s*<([^>]+)>" sparql)))
    (map (lambda (m) (match:substring m 1)) matches)))

(define (list-matches pattern str)
  "Return all regex matches of PATTERN in STR."
  (let ((rx (make-regexp pattern regexp/icase)))
    (let loop ((start 0) (acc '()))
      (let ((m (regexp-exec rx str start)))
        (if m
            (loop (match:end m) (cons m acc))
            (reverse acc))))))

;;; --------------------------------------------------------------------
;;; Graph Gatekeeper Actor
;;; --------------------------------------------------------------------

(define (^graph-gatekeeper bcom store cap-store)
  "Create a Graph Gatekeeper actor.
   STORE: the Oxigraph store (from xm/store.scm)
   CAP-STORE: the capability store actor

   The gatekeeper validates all operations against capabilities and
   rewrites queries to enforce graph-level access control."

  (methods
   ;; Execute a SPARQL SELECT/ASK/CONSTRUCT/DESCRIBE query
   [(query cap-id sparql)
    (let ((allowed-graphs (resolve-allowed-graphs bcom cap-store cap-id 'read)))
      (when (null? allowed-graphs)
        (error "No readable graphs in capability scope"))
      (let ((scoped-query (rewrite-query-with-graphs sparql allowed-graphs)))
        (store-query store scoped-query)))]

   ;; Execute a SPARQL UPDATE query (INSERT DATA, DELETE DATA)
   [(update cap-id sparql)
    (let ((allowed-graphs (resolve-allowed-graphs bcom cap-store cap-id 'write)))
      (when (null? allowed-graphs)
        (error "No writable graphs in capability scope"))
      ;; Validate that all graphs in the update are allowed
      (let ((update-graphs (extract-update-graphs sparql)))
        (for-each
         (lambda (g)
           (unless (member g allowed-graphs)
             (error "Write to graph not allowed by capability" g)))
         update-graphs))
      (store-update store sparql))]

   ;; Insert triples into a specific graph
   [(insert cap-id graph-uri triples-turtle)
    (validate-graph-access bcom cap-store cap-id graph-uri 'write)
    (store-load-graph store triples-turtle #:graph graph-uri #:format "turtle")]

   ;; Delete triples matching a pattern from a graph
   [(delete cap-id graph-uri pattern-sparql)
    (validate-graph-access bcom cap-store cap-id graph-uri 'write)
    (let ((delete-query (format #f "DELETE WHERE { GRAPH <~a> { ~a } }"
                                graph-uri pattern-sparql)))
      (store-update store delete-query))]

   ;; Clear an entire graph (admin permission required)
   [(clear-graph cap-id graph-uri)
    (validate-graph-access bcom cap-store cap-id graph-uri 'admin)
    (let ((clear-query (format #f "CLEAR GRAPH <~a>" graph-uri)))
      (store-update store clear-query))]

   ;; Dump a graph to RDF format
   [(dump-graph cap-id graph-uri format)
    (validate-graph-access bcom cap-store cap-id graph-uri 'read)
    (store-dump-graph store #:graph graph-uri #:format format)]

   ;; Get store statistics
   [(stats)
    `((quad-count . ,(store-count store))
      (empty . ,(store-empty? store)))]

   ;; Public query (no capability required, scoped to public graph)
   [(public-query sparql)
    (let ((scoped-query (rewrite-query-with-graphs sparql (list public-graph-uri))))
      (store-query store scoped-query))]

   ;; Insert into public graph (no capability required for public writes)
   [(public-insert triples-turtle)
    (store-load-graph store triples-turtle
                      #:graph public-graph-uri
                      #:format "turtle")]))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (resolve-allowed-graphs bcom cap-store cap-id permission)
  "Resolve the list of graphs allowed for the given capability and permission.
   Always includes the public graph for read operations.
   Returns empty list if capability is invalid."

  (if (not cap-id)
      ;; No capability - only public graph for reads
      (if (eq? permission 'read)
          (list public-graph-uri)
          '())
      ;; Validate capability and get allowed graphs
      (let-values (((cap err) (<- cap-store 'validate cap-id)))
        (if err
            (error "Invalid capability" cap-id err)
            (let ((graphs (capability-graphs cap)))
              ;; Check if capability has required permission
              (if (capability-has-permission? cap permission)
                  ;; Add public graph for reads
                  (if (eq? permission 'read)
                      (delete-duplicates (cons public-graph-uri graphs))
                      graphs)
                  '()))))))

(define (validate-graph-access bcom cap-store cap-id graph-uri permission)
  "Validate that capability allows the specified access to graph.
   Raises an error if access is denied."
  (let ((allowed-graphs (resolve-allowed-graphs bcom cap-store cap-id permission)))
    (unless (member graph-uri allowed-graphs)
      (error (format #f "Access denied: ~a permission to graph ~a"
                     permission graph-uri)
             cap-id graph-uri permission))))

(define (delete-duplicates lst)
  "Remove duplicate elements from a list."
  (let loop ((lst lst) (seen '()) (result '()))
    (if (null? lst)
        (reverse result)
        (let ((item (car lst)))
          (if (member item seen)
              (loop (cdr lst) seen result)
              (loop (cdr lst) (cons item seen) (cons item result)))))))
