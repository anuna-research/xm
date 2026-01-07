;;; xm/vocabulary.scm --- RDF namespace prefixes and URI utilities
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This module defines standard RDF vocabularies used by xm,
;;; following the namespace prefixes defined in SPEC-029 Section 4.3.

(define-module (xm vocabulary)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:export (;; Namespace URIs
            rdf-ns rdfs-ns xsd-ns prov-ns dcterms-ns skos-ns xm-ns

            ;; Prefix expansion
            expand-uri
            compact-uri
            register-prefix!
            get-prefix

            ;; Common predicates
            rdf:type
            rdfs:label rdfs:comment
            prov:wasAttributedTo prov:wasGeneratedBy prov:hadPrimarySource
            dcterms:created dcterms:modified dcterms:replaces
            skos:related
            xm:confidence xm:dependsOn xm:uses
            xm:from xm:to xm:predicate

            ;; Common classes
            prov:Entity prov:Activity prov:SoftwareAgent
            xm:Capability xm:Link

            ;; Node type URIs
            xm-node-type-uri
            xm-node-uri
            xm-link-uri
            xm-session-uri
            xm-cap-uri
            xm-graph-uri))

;;; --------------------------------------------------------------------
;;; Namespace URIs (from SPEC-029 Section 4.3.1)
;;; --------------------------------------------------------------------

(define rdf-ns "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
(define rdfs-ns "http://www.w3.org/2000/01/rdf-schema#")
(define xsd-ns "http://www.w3.org/2001/XMLSchema#")
(define prov-ns "http://www.w3.org/ns/prov#")
(define dcterms-ns "http://purl.org/dc/terms/")
(define skos-ns "http://www.w3.org/2004/02/skos/core#")
(define xm-ns "https://xm.dev/ns/v1#")

;;; --------------------------------------------------------------------
;;; Prefix Registry
;;; --------------------------------------------------------------------

(define *prefix-table*
  (make-hash-table))

;; Initialize with standard prefixes
(hash-set! *prefix-table* "rdf" rdf-ns)
(hash-set! *prefix-table* "rdfs" rdfs-ns)
(hash-set! *prefix-table* "xsd" xsd-ns)
(hash-set! *prefix-table* "prov" prov-ns)
(hash-set! *prefix-table* "dcterms" dcterms-ns)
(hash-set! *prefix-table* "skos" skos-ns)
(hash-set! *prefix-table* "xm" xm-ns)

(define (register-prefix! prefix uri)
  "Register a namespace prefix for URI expansion."
  (hash-set! *prefix-table* prefix uri))

(define (get-prefix prefix)
  "Get the namespace URI for a prefix, or #f if not found."
  (hash-ref *prefix-table* prefix #f))

;;; --------------------------------------------------------------------
;;; URI Expansion and Compaction
;;; --------------------------------------------------------------------

(define prefixed-uri-rx
  (make-regexp "^([a-zA-Z][a-zA-Z0-9]*):(.+)$"))

(define (expand-uri uri)
  "Expand a prefixed URI (e.g., 'dcterms:created') to full URI.
   If already a full URI or no matching prefix, returns unchanged.
   Unprefixed names expand to xm: namespace."
  (cond
   ;; Already a full URI
   ((or (string-prefix? "http://" uri)
        (string-prefix? "https://" uri))
    uri)
   ;; Prefixed URI (prefix:local)
   ((regexp-exec prefixed-uri-rx uri)
    => (lambda (match)
         (let* ((prefix (match:substring match 1))
                (local (match:substring match 2))
                (ns (get-prefix prefix)))
           (if ns
               (string-append ns local)
               ;; Unknown prefix, return as-is
               uri))))
   ;; Unprefixed - assume xm: namespace
   (else
    (string-append xm-ns uri))))

(define (compact-uri full-uri)
  "Compact a full URI to prefixed form if possible.
   Returns the shortest prefixed form, or the original URI."
  (let loop ((prefixes (hash-map->list cons *prefix-table*))
             (best-result full-uri)
             (best-len (string-length full-uri)))
    (if (null? prefixes)
        best-result
        (let* ((prefix-pair (car prefixes))
               (prefix (car prefix-pair))
               (ns (cdr prefix-pair)))
          (if (string-prefix? ns full-uri)
              (let* ((local (substring full-uri (string-length ns)))
                     (compact (string-append prefix ":" local))
                     (compact-len (string-length compact)))
                (if (< compact-len best-len)
                    (loop (cdr prefixes) compact compact-len)
                    (loop (cdr prefixes) best-result best-len)))
              (loop (cdr prefixes) best-result best-len))))))

;;; --------------------------------------------------------------------
;;; Common Predicates (full URIs)
;;; --------------------------------------------------------------------

;; RDF
(define rdf:type (string-append rdf-ns "type"))

;; RDFS
(define rdfs:label (string-append rdfs-ns "label"))
(define rdfs:comment (string-append rdfs-ns "comment"))

;; PROV-O
(define prov:wasAttributedTo (string-append prov-ns "wasAttributedTo"))
(define prov:wasGeneratedBy (string-append prov-ns "wasGeneratedBy"))
(define prov:hadPrimarySource (string-append prov-ns "hadPrimarySource"))

;; Dublin Core Terms
(define dcterms:created (string-append dcterms-ns "created"))
(define dcterms:modified (string-append dcterms-ns "modified"))
(define dcterms:replaces (string-append dcterms-ns "replaces"))

;; SKOS
(define skos:related (string-append skos-ns "related"))

;; xm-specific
(define xm:confidence (string-append xm-ns "confidence"))
(define xm:dependsOn (string-append xm-ns "dependsOn"))
(define xm:uses (string-append xm-ns "uses"))
(define xm:from (string-append xm-ns "from"))
(define xm:to (string-append xm-ns "to"))
(define xm:predicate (string-append xm-ns "predicate"))

;;; --------------------------------------------------------------------
;;; Common Classes (full URIs)
;;; --------------------------------------------------------------------

;; PROV-O
(define prov:Entity (string-append prov-ns "Entity"))
(define prov:Activity (string-append prov-ns "Activity"))
(define prov:SoftwareAgent (string-append prov-ns "SoftwareAgent"))

;; xm-specific
(define xm:Capability (string-append xm-ns "Capability"))
(define xm:Link (string-append xm-ns "Link"))

;;; --------------------------------------------------------------------
;;; URI Generators
;;; --------------------------------------------------------------------

(define (xm-node-type-uri type)
  "Get the RDF class URI for a node type symbol.
   TYPE is one of: 'fact, 'entity, 'session, 'agent, 'artifact"
  (case type
    ((fact entity artifact) prov:Entity)
    ((session) prov:Activity)
    ((agent) prov:SoftwareAgent)
    (else (string-append xm-ns (symbol->string type)))))

(define (xm-node-uri uuid)
  "Generate a node URI from a UUID string."
  (string-append xm-ns "node/" uuid))

(define (xm-link-uri uuid)
  "Generate a link URI from a UUID string."
  (string-append xm-ns "link/" uuid))

(define (xm-session-uri uuid)
  "Generate a session URI from a UUID string."
  (string-append xm-ns "session/" uuid))

(define (xm-cap-uri token)
  "Generate a capability URI from a token string."
  (string-append xm-ns "cap/" token))

(define (xm-graph-uri . path-components)
  "Generate a named graph URI from path components.
   Example: (xm-graph-uri \"project\" \"acme-api\") => \"xm:graph/project/acme-api\""
  (string-append xm-ns "graph/"
                 (string-join path-components "/")))
