;;; xm/gatekeeper.scm --- Graph Gatekeeper actor for xm
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; The Graph Gatekeeper is the core storage actor in xm. It provides:
;;; - Direct access to Oxigraph SPARQL operations
;;; - Public graph queries (no capability required)
;;; - Internal methods called by capability facets
;;;
;;; CAPABILITY MODEL (per Spritely Goblins):
;;;
;;; The gatekeeper itself is NOT the capability. Instead:
;;; 1. ^graph-facet actors wrap the gatekeeper with access restrictions
;;; 2. The facet IS the capability - whoever has the actor reference can use it
;;; 3. Attenuation = spawn facets with stricter constraints
;;; 4. Network sharing = register facet with mycapn → get sturdyref
;;;
;;; See xm/capability.scm for the facet implementation.

(define-module (xm gatekeeper)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (xm store)
  #:use-module (xm vocabulary)
  #:export (^graph-gatekeeper
            public-graph-uri
            make-root-capability))

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

   Example:
   Input:  SELECT ?s ?p ?o WHERE { ?s ?p ?o }
   Output: SELECT ?s ?p ?o FROM <graph1> FROM <graph2> WHERE { ?s ?p ?o }"

  (let ((query-type (detect-query-type sparql)))
    (case query-type
      ((select ask construct describe)
       (add-from-clauses sparql allowed-graphs))
      ((insert delete update)
       ;; UPDATE queries - passed through, graph validation done by facet
       sparql)
      (else
       (error "Unknown query type" sparql)))))

(define (detect-query-type sparql)
  "Detect the type of SPARQL query.
   Handles PREFIX/BASE declarations at the start of the query."
  (let* ((upper (string-upcase (string-trim sparql)))
         ;; Skip PREFIX and BASE declarations to find actual query type
         (body (skip-sparql-prologue upper)))
    (cond
     ((string-prefix? "SELECT" body) 'select)
     ((string-prefix? "ASK" body) 'ask)
     ((string-prefix? "CONSTRUCT" body) 'construct)
     ((string-prefix? "DESCRIBE" body) 'describe)
     ((string-prefix? "INSERT" body) 'insert)
     ((string-prefix? "DELETE" body) 'delete)
     ((string-prefix? "WITH" body) 'update)  ; WITH ... DELETE/INSERT
     (else 'unknown))))

(define (skip-sparql-prologue sparql)
  "Skip PREFIX and BASE declarations at the start of a SPARQL query.
   Returns the remaining query body."
  (let ((trimmed (string-trim sparql)))
    (cond
     ((string-prefix? "PREFIX" trimmed)
      ;; Skip to end of PREFIX declaration (after the URI)
      (let ((gt-pos (string-index trimmed #\>)))
        (if gt-pos
            (skip-sparql-prologue (substring trimmed (+ gt-pos 1)))
            trimmed)))
     ((string-prefix? "BASE" trimmed)
      ;; Skip to end of BASE declaration (after the URI)
      (let ((gt-pos (string-index trimmed #\>)))
        (if gt-pos
            (skip-sparql-prologue (substring trimmed (+ gt-pos 1)))
            trimmed)))
     (else trimmed))))

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

(define (string-join strs sep)
  "Join strings with separator."
  (if (null? strs)
      ""
      (let loop ((strs (cdr strs)) (acc (car strs)))
        (if (null? strs)
            acc
            (loop (cdr strs) (string-append acc sep (car strs)))))))

;;; --------------------------------------------------------------------
;;; Graph Gatekeeper Actor
;;; --------------------------------------------------------------------

(define (^graph-gatekeeper bcom store)
  "Create a Graph Gatekeeper actor.

   STORE: the Oxigraph store (from xm/store.scm)

   The gatekeeper provides two types of methods:

   1. PUBLIC methods - callable by anyone with a gatekeeper reference
      (query public graph, get stats)

   2. INTERNAL methods - called by capability facets only
      (suffixed with -internal, trust the caller has validated access)

   Capability facets (^graph-facet) wrap this gatekeeper and enforce
   access control before calling internal methods."

  (methods
   ;;; ================================================================
   ;;; PUBLIC METHODS - No capability required
   ;;; ================================================================

   ;; Query the public graph only
   [(public-query sparql)
    (let ((scoped-query (rewrite-query-with-graphs sparql (list public-graph-uri))))
      (store-query store scoped-query))]

   ;; Insert into public graph (for bootstrapping/shared knowledge)
   [(public-insert triples-turtle)
    (store-load-graph store triples-turtle
                      #:graph public-graph-uri
                      #:format "turtle")]

   ;; Get store statistics
   [(stats)
    `((quad-count . ,(store-count store))
      (empty . ,(store-empty? store)))]

   ;; Check if store is empty
   [(empty?)
    (store-empty? store)]

   ;;; ================================================================
   ;;; INTERNAL METHODS - Called by capability facets
   ;;; ================================================================
   ;;;
   ;;; These methods TRUST the caller to have validated access rights.
   ;;; They should only be called by ^graph-facet actors which enforce
   ;;; the capability constraints.
   ;;;
   ;;; DO NOT expose these methods directly to untrusted code.

   ;; Query with specific graphs (facet passes its allowed graphs)
   [(query-with-graphs sparql allowed-graphs)
    (let ((scoped-query (rewrite-query-with-graphs sparql allowed-graphs)))
      (store-query store scoped-query))]

   ;; Insert triples into a graph (facet has validated write access)
   [(insert-internal graph-uri triples-turtle)
    (store-load-graph store triples-turtle
                      #:graph graph-uri
                      #:format "turtle")]

   ;; Execute SPARQL UPDATE (facet has validated write access)
   [(update-internal sparql)
    (store-update store sparql)]

   ;; Delete triples matching pattern (facet has validated write access)
   [(delete-internal graph-uri pattern-sparql)
    (let ((delete-query (format #f "DELETE WHERE { GRAPH <~a> { ~a } }"
                                graph-uri pattern-sparql)))
      (store-update store delete-query))]

   ;; Clear an entire graph (facet has validated admin access)
   [(clear-graph-internal graph-uri)
    (let ((clear-query (format #f "CLEAR GRAPH <~a>" graph-uri)))
      (store-update store clear-query))]

   ;; Dump a graph to RDF format (facet has validated read access)
   [(dump-graph-internal graph-uri rdf-format)
    (store-dump-graph store #:graph graph-uri #:format rdf-format)]

   ;; Create a new named graph (facet has validated admin access)
   [(create-graph-internal graph-uri)
    ;; In SPARQL, creating a graph is implicit - insert empty to ensure it exists
    (let ((create-query (format #f "CREATE SILENT GRAPH <~a>" graph-uri)))
      (store-update store create-query))]

   ;; List all named graphs in the store
   [(list-graphs)
    (store-query store "SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }")]

   ;;; ================================================================
   ;;; CAPABILITY CREATION - Bootstrap method
   ;;; ================================================================
   ;;;
   ;;; This method creates the root capability facet for a set of graphs.
   ;;; It should be called once during initialization to create the
   ;;; initial capability, which can then be attenuated and shared.

   ;; Create a root capability facet for this gatekeeper
   ;; Returns a ^graph-facet actor reference (THE CAPABILITY)
   [(create-capability graphs ops #:optional label)
    ;; Import the facet constructor dynamically to avoid circular deps
    (let ((^graph-facet (@ (xm capability) ^graph-facet)))
      ;; Spawn the facet - the returned actor reference IS the capability
      (spawn ^graph-facet
             ;; self is the gatekeeper this facet wraps
             (actormap-peek (current-actormap) (lambda () bcom) #f)
             graphs
             ops
             #:label label))]))

;;; --------------------------------------------------------------------
;;; Helper: Create Root Capability
;;; --------------------------------------------------------------------

(define* (make-root-capability gatekeeper graphs ops #:key label)
  "Create a root capability facet for the gatekeeper.

   GATEKEEPER: the ^graph-gatekeeper actor reference
   GRAPHS: list of graph URIs to grant access to
   OPS: list of operations ('read 'write 'admin)
   LABEL: optional human-readable label

   Returns a ^graph-facet actor reference - THIS IS THE CAPABILITY.
   Share this reference (or attenuated versions) to grant access."

  ;; Import here to avoid module load order issues
  (let ((^graph-facet (@ (xm capability) ^graph-facet)))
    (spawn ^graph-facet gatekeeper graphs ops #:label label)))

;;; --------------------------------------------------------------------
;;; Usage Example
;;; --------------------------------------------------------------------
;;;
;;; ;; Create the gatekeeper (once, at startup)
;;; (define gatekeeper (spawn ^graph-gatekeeper store))
;;;
;;; ;; Create a root capability with full access
;;; (define root-cap
;;;   (make-root-capability gatekeeper
;;;                         '("xm:graph/project/acme-api"
;;;                           "xm:graph/project/web-frontend")
;;;                         '(read write admin)
;;;                         #:label "Root admin access"))
;;;
;;; ;; Attenuate to create a read-only capability
;;; (define read-only-cap
;;;   (<- root-cap 'attenuate #:ops '(read) #:new-label "Read-only access"))
;;;
;;; ;; Share over network via OCapN
;;; (define sturdyref (<- mycapn 'register read-only-cap 'onion))
;;; (define shareable-uri (ocapn-id->string sturdyref))
;;;
;;; ;; Remote agent enlivens the sturdyref to get live capability
;;; (define remote-cap (<- mycapn 'enliven (string->ocapn-id uri)))
;;;
;;; ;; Remote agent can now query (but not write)
;;; (<- remote-cap 'query "SELECT ?s ?p ?o WHERE { ?s ?p ?o }")
