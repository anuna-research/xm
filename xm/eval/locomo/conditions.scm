;;; eval/locomo/conditions.scm --- Experimental conditions for LoCoMo evaluation
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module defines the different retrieval conditions to compare
;;; in the LoCoMo evaluation. Each condition represents a different
;;; approach to using xm's SPARQL graph for memory retrieval.

(define-module (eval locomo conditions)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (eval locomo retrieve)
  #:use-module (xm store)
  #:export (*conditions*
            get-condition
            make-retriever
            condition-xm-sparql
            condition-xm-backlinks
            condition-xm-path
            condition-xm-observations
            condition-xm-events
            condition-xm-hybrid
            condition-baseline-raw))

;;; --------------------------------------------------------------------
;;; Condition Registry
;;; --------------------------------------------------------------------

(define *conditions*
  '((xm-sparql . "SPARQL text search over xm graph")
    (xm-backlinks . "Entity-based backlink traversal")
    (xm-path . "Path queries for multi-hop reasoning")
    (xm-observations . "Pre-extracted observations only")
    (xm-events . "Event summaries (temporal focus)")
    (xm-hybrid . "Combined SPARQL + observations + events")
    (baseline-raw . "Raw dialog text (no xm)")
    (baseline-obs . "LoCoMo observations without graph")))

(define (get-condition name)
  "Get condition description by name."
  (assoc-ref *conditions* name))

;;; --------------------------------------------------------------------
;;; Retriever Factory
;;; --------------------------------------------------------------------

(define* (make-retriever condition #:key (max-tokens 4000))
  "Create a retriever function for the given condition.
   Returns a procedure (retriever store conv-id question) -> context-result."
  (case condition
    ((xm-sparql)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'sparql #:max-tokens max-tokens)))

    ((xm-backlinks)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'backlinks #:max-tokens max-tokens)))

    ((xm-path)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'path #:max-tokens max-tokens)))

    ((xm-observations)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'observations #:max-tokens max-tokens)))

    ((xm-events)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'events #:max-tokens max-tokens)))

    ((xm-hybrid)
     (lambda (store conv-id question)
       (retrieve-context store conv-id question 'hybrid #:max-tokens max-tokens)))

    ((baseline-raw)
     (lambda (store conv-id question)
       ;; Return raw dialog without xm graph queries
       (baseline-raw-retriever store conv-id question max-tokens)))

    ((baseline-obs)
     (lambda (store conv-id question)
       ;; Return only observations as flat text
       (baseline-observations-retriever store conv-id question max-tokens)))

    (else
     (error "Unknown condition" condition))))

;;; --------------------------------------------------------------------
;;; xm-based Conditions (wrappers around retrieve.scm)
;;; --------------------------------------------------------------------

(define (condition-xm-sparql store conv-id question max-tokens)
  "SPARQL-based retrieval using text search.
   Tests: Can SPARQL text queries find relevant information?"
  (retrieve-context store conv-id question 'sparql #:max-tokens max-tokens))

(define (condition-xm-backlinks store conv-id question max-tokens)
  "Backlink traversal from extracted entities.
   Tests: Does entity-based navigation improve recall?"
  (retrieve-context store conv-id question 'backlinks #:max-tokens max-tokens))

(define (condition-xm-path store conv-id question max-tokens)
  "Path queries between entities.
   Tests: Do graph paths help multi-hop reasoning?"
  (retrieve-context store conv-id question 'path #:max-tokens max-tokens))

(define (condition-xm-observations store conv-id question max-tokens)
  "Pre-extracted observations only.
   Tests: Are distilled observations more efficient?"
  (retrieve-context store conv-id question 'observations #:max-tokens max-tokens))

(define (condition-xm-events store conv-id question max-tokens)
  "Event summaries with dates.
   Tests: Do structured events help temporal queries?"
  (retrieve-context store conv-id question 'events #:max-tokens max-tokens))

(define (condition-xm-hybrid store conv-id question max-tokens)
  "Combined retrieval: observations + events + utterances.
   Tests: Does combining strategies improve overall performance?"
  (retrieve-context store conv-id question 'hybrid #:max-tokens max-tokens))

;;; --------------------------------------------------------------------
;;; Baseline Conditions (without xm graph benefits)
;;; --------------------------------------------------------------------

(define (baseline-raw-retriever store conv-id question max-tokens)
  "Retrieve raw dialog text without graph structure.
   This is the control condition - simulates simple RAG over flat text."
  (let* ((graph-uri (string-append "https://xm.dev/ns/v1#graph/locomo/" conv-id))
         ;; Get all utterances in order
         (sparql (format #f "
PREFIX locomo: <https://xm.dev/ns/v1#locomo/>
SELECT ?text ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?utt a locomo:Utterance ;
       locomo:text ?text ;
       locomo:inSession ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:said ?utt ;
         locomo:name ?speaker .
}
ORDER BY ?sessionIdx
" graph-uri))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed))
         ;; Format as flat text
         (context-lines (map (lambda (b)
                               (format #f "~a: ~a"
                                       (binding-value b "speaker")
                                       (binding-value b "text")))
                             bindings))
         (context (string-join context-lines "\n")))
    ;; Truncate to max tokens
    `((context . ,(truncate-to-tokens context max-tokens))
      (metadata . ((strategy . baseline-raw)
                   (total_utterances . ,(length bindings)))))))

(define (baseline-observations-retriever store conv-id question max-tokens)
  "Retrieve observations as flat text (no graph links).
   This tests observations without exploiting graph structure."
  (let* ((graph-uri (string-append "https://xm.dev/ns/v1#graph/locomo/" conv-id))
         (sparql (format #f "
PREFIX locomo: <https://xm.dev/ns/v1#locomo/>
SELECT ?text ?speaker
FROM <~a>
WHERE {
  ?obs a locomo:Observation ;
       locomo:text ?text .
  ?agent locomo:experienced ?obs ;
         locomo:name ?speaker .
}
" graph-uri))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed))
         (context-lines (map (lambda (b)
                               (format #f "[~a] ~a"
                                       (binding-value b "speaker")
                                       (binding-value b "text")))
                             bindings))
         (context (string-join context-lines "\n")))
    `((context . ,(truncate-to-tokens context max-tokens))
      (metadata . ((strategy . baseline-obs)
                   (total_observations . ,(length bindings)))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (truncate-to-tokens text max-tokens)
  "Truncate text to approximately max-tokens (1 token ≈ 4 chars)."
  (let ((max-chars (* max-tokens 4)))
    (if (> (string-length text) max-chars)
        (substring text 0 max-chars)
        text)))

(define (get-sparql-bindings json-obj)
  "Extract bindings from SPARQL JSON results."
  (let ((results (assoc-ref json-obj "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-binding (assoc-ref binding var-name)))
    (if var-binding
        (or (assoc-ref var-binding "value") "")
        "")))
