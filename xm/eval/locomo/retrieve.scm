;;; eval/locomo/retrieve.scm --- Query strategies for LoCoMo evaluation
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements different retrieval strategies for answering
;;; LoCoMo questions using the xm RDF store.

(define-module (eval locomo retrieve)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (xm store)
  #:use-module (xm vocabulary)
  #:export (retrieve-context
            retrieve-sparql
            retrieve-backlinks
            retrieve-path
            retrieve-observations
            retrieve-events
            retrieve-hybrid
            extract-entities
            format-context-for-llm))

;;; --------------------------------------------------------------------
;;; LoCoMo-specific namespace (duplicated for module independence)
;;; --------------------------------------------------------------------

(define locomo-ns (string-append xm-ns "locomo/"))

;;; --------------------------------------------------------------------
;;; Main Retrieval Interface
;;; --------------------------------------------------------------------

(define* (retrieve-context store conv-id question strategy #:key (max-tokens 4000))
  "Retrieve context from xm for answering QUESTION using STRATEGY.
   STRATEGY is one of: 'sparql, 'backlinks, 'path, 'observations, 'events, 'hybrid
   Returns an alist with 'context (string) and 'metadata (retrieval stats)."
  (let ((graph-uri (string-append xm-ns "graph/locomo/" conv-id)))
    (case strategy
      ((sparql)
       (retrieve-sparql store graph-uri question max-tokens))
      ((backlinks)
       (retrieve-backlinks store graph-uri question max-tokens))
      ((path)
       (retrieve-path store graph-uri question max-tokens))
      ((observations)
       (retrieve-observations store graph-uri question max-tokens))
      ((events)
       (retrieve-events store graph-uri question max-tokens))
      ((hybrid)
       (retrieve-hybrid store graph-uri question max-tokens))
      (else
       (error "Unknown retrieval strategy" strategy)))))

;;; --------------------------------------------------------------------
;;; SPARQL-based Retrieval
;;; --------------------------------------------------------------------

(define (retrieve-sparql store graph-uri question max-tokens)
  "Use SPARQL queries to find relevant context.
   Searches utterances, observations, and events matching question terms."
  (let* ((search-terms (extract-search-terms question))
         (utterances (query-matching-utterances store graph-uri search-terms))
         (observations (query-matching-observations store graph-uri search-terms))
         (events (query-matching-events store graph-uri search-terms))
         (all-context (append utterances observations events))
         (context-str (format-context-for-llm all-context max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . sparql)
                   (search_terms . ,search-terms)
                   (utterances_found . ,(length utterances))
                   (observations_found . ,(length observations))
                   (events_found . ,(length events))
                   (total_items . ,(length all-context)))))))

(define (query-matching-utterances store graph-uri search-terms)
  "Query utterances containing any of the search terms."
  (if (null? search-terms)
      '()
      (let* ((filter-clause (build-text-filter "?text" search-terms))
             (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?diaId ?speaker ?text ?sessionIdx
FROM <~a>
WHERE {
  ?utt a locomo:Utterance ;
       locomo:diaId ?diaId ;
       locomo:text ?text ;
       locomo:inSession ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:said ?utt ;
         locomo:name ?speaker .
  ~a
}
ORDER BY ?sessionIdx ?diaId
LIMIT 50" locomo-ns graph-uri filter-clause))
             (json-result (store-query store sparql))
             (parsed (json-string->scm json-result))
             (bindings (get-sparql-bindings parsed)))
        (map (lambda (b)
               `((type . utterance)
                 (diaId . ,(binding-value b "diaId"))
                 (speaker . ,(binding-value b "speaker"))
                 (text . ,(binding-value b "text"))
                 (sessionIdx . ,(binding-value b "sessionIdx"))))
             bindings))))

(define (query-matching-observations store graph-uri search-terms)
  "Query observations containing any of the search terms."
  (if (null? search-terms)
      '()
      (let* ((filter-clause (build-text-filter "?text" search-terms))
             (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?text ?evidenceRef ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?obs a locomo:Observation ;
       locomo:text ?text ;
       locomo:evidenceRef ?evidenceRef ;
       locomo:occursIn ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:experienced ?obs ;
         locomo:name ?speaker .
  ~a
}
ORDER BY ?sessionIdx
LIMIT 30" locomo-ns graph-uri filter-clause))
             (json-result (store-query store sparql))
             (parsed (json-string->scm json-result))
             (bindings (get-sparql-bindings parsed)))
        (map (lambda (b)
               `((type . observation)
                 (text . ,(binding-value b "text"))
                 (evidenceRef . ,(binding-value b "evidenceRef"))
                 (speaker . ,(binding-value b "speaker"))
                 (sessionIdx . ,(binding-value b "sessionIdx"))))
             bindings))))

(define (query-matching-events store graph-uri search-terms)
  "Query events containing any of the search terms."
  (if (null? search-terms)
      '()
      (let* ((filter-clause (build-text-filter "?text" search-terms))
             (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?text ?date ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?evt a locomo:Event ;
       locomo:text ?text ;
       locomo:occursIn ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:experienced ?evt ;
         locomo:name ?speaker .
  OPTIONAL { ?evt locomo:date ?date }
  ~a
}
ORDER BY ?sessionIdx
LIMIT 20" locomo-ns graph-uri filter-clause))
             (json-result (store-query store sparql))
             (parsed (json-string->scm json-result))
             (bindings (get-sparql-bindings parsed)))
        (map (lambda (b)
               `((type . event)
                 (text . ,(binding-value b "text"))
                 (date . ,(binding-value b "date"))
                 (speaker . ,(binding-value b "speaker"))
                 (sessionIdx . ,(binding-value b "sessionIdx"))))
             bindings))))

;;; --------------------------------------------------------------------
;;; Backlink-based Retrieval
;;; --------------------------------------------------------------------

(define (retrieve-backlinks store graph-uri question max-tokens)
  "Extract entities from question and find all context linked to them.
   This mimics Org-roam's backlink navigation."
  (let* ((entities (extract-entities question))
         (speaker-contexts (if (null? entities)
                               '()
                               (query-speaker-context store graph-uri entities)))
         (all-context speaker-contexts)
         (context-str (format-context-for-llm all-context max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . backlinks)
                   (entities . ,entities)
                   (items_found . ,(length all-context)))))))

(define (query-speaker-context store graph-uri speaker-names)
  "Get all utterances and events for named speakers."
  (let* ((name-filter (build-name-filter speaker-names))
         (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?type ?text ?diaId ?date ?sessionIdx ?speaker
FROM <~a>
WHERE {
  ?agent locomo:name ?speaker .
  ~a
  {
    ?agent locomo:said ?item .
    ?item a locomo:Utterance ;
          locomo:text ?text ;
          locomo:diaId ?diaId ;
          locomo:inSession ?session .
    ?session locomo:sessionIndex ?sessionIdx .
    BIND('utterance' AS ?type)
  } UNION {
    ?agent locomo:experienced ?item .
    ?item a locomo:Event ;
          locomo:text ?text ;
          locomo:occursIn ?session .
    ?session locomo:sessionIndex ?sessionIdx .
    OPTIONAL { ?item locomo:date ?date }
    BIND('event' AS ?type)
    BIND('' AS ?diaId)
  } UNION {
    ?agent locomo:experienced ?item .
    ?item a locomo:Observation ;
          locomo:text ?text ;
          locomo:occursIn ?session .
    ?session locomo:sessionIndex ?sessionIdx .
    BIND('observation' AS ?type)
    BIND('' AS ?diaId)
  }
}
ORDER BY ?sessionIdx
LIMIT 100" locomo-ns graph-uri name-filter))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b)
           `((type . ,(string->symbol (binding-value b "type")))
             (text . ,(binding-value b "text"))
             (diaId . ,(binding-value b "diaId"))
             (date . ,(binding-value b "date"))
             (sessionIdx . ,(binding-value b "sessionIdx"))
             (speaker . ,(binding-value b "speaker"))))
         bindings)))

;;; --------------------------------------------------------------------
;;; Path-based Retrieval (for Multi-hop)
;;; --------------------------------------------------------------------

(define (retrieve-path store graph-uri question max-tokens)
  "Find paths between entities for multi-hop reasoning.
   Retrieves connected subgraph around question entities."
  (let* ((entities (extract-entities question))
         ;; Get direct context for entities
         (direct-context (query-speaker-context store graph-uri entities))
         ;; Get follow chains for dialog context
         (follow-chains (query-dialog-chains store graph-uri entities))
         (all-context (append direct-context follow-chains))
         (context-str (format-context-for-llm all-context max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . path)
                   (entities . ,entities)
                   (direct_items . ,(length direct-context))
                   (chain_items . ,(length follow-chains)))))))

(define (query-dialog-chains store graph-uri speaker-names)
  "Get dialog chains involving speakers (follows relationships)."
  (let* ((name-filter (build-name-filter speaker-names))
         (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?text ?diaId ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?agent locomo:name ?speaker1 .
  ~a
  ?agent locomo:said ?utt1 .
  ?utt2 locomo:follows* ?utt1 .
  ?utt2 locomo:text ?text ;
        locomo:diaId ?diaId ;
        locomo:inSession ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent2 locomo:said ?utt2 ;
          locomo:name ?speaker .
}
ORDER BY ?sessionIdx ?diaId
LIMIT 50" locomo-ns graph-uri
                         (string-append "FILTER(?speaker1 IN ("
                                        (string-join
                                         (map (lambda (n) (format #f "\"~a\"" n))
                                              speaker-names)
                                         ", ")
                                        "))")))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b)
           `((type . dialog-chain)
             (text . ,(binding-value b "text"))
             (diaId . ,(binding-value b "diaId"))
             (speaker . ,(binding-value b "speaker"))
             (sessionIdx . ,(binding-value b "sessionIdx"))))
         bindings)))

;;; --------------------------------------------------------------------
;;; Observation-focused Retrieval
;;; --------------------------------------------------------------------

(define (retrieve-observations store graph-uri question max-tokens)
  "Retrieve pre-extracted observations (LoCoMo's own observation summaries)."
  (let* ((search-terms (extract-search-terms question))
         (observations (query-all-observations store graph-uri search-terms))
         (context-str (format-context-for-llm observations max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . observations)
                   (items_found . ,(length observations)))))))

(define (query-all-observations store graph-uri search-terms)
  "Query all observations, optionally filtered by search terms."
  (let* ((filter-clause (if (null? search-terms)
                            ""
                            (build-text-filter "?text" search-terms)))
         (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?text ?evidenceRef ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?obs a locomo:Observation ;
       locomo:text ?text ;
       locomo:evidenceRef ?evidenceRef ;
       locomo:occursIn ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:experienced ?obs ;
         locomo:name ?speaker .
  ~a
}
ORDER BY ?sessionIdx" locomo-ns graph-uri filter-clause))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b)
           `((type . observation)
             (text . ,(binding-value b "text"))
             (evidenceRef . ,(binding-value b "evidenceRef"))
             (speaker . ,(binding-value b "speaker"))
             (sessionIdx . ,(binding-value b "sessionIdx"))))
         bindings)))

;;; --------------------------------------------------------------------
;;; Event-focused Retrieval
;;; --------------------------------------------------------------------

(define (retrieve-events store graph-uri question max-tokens)
  "Retrieve events, useful for temporal questions."
  (let* ((search-terms (extract-search-terms question))
         (events (query-all-events store graph-uri search-terms))
         (context-str (format-context-for-llm events max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . events)
                   (items_found . ,(length events)))))))

(define (query-all-events store graph-uri search-terms)
  "Query all events, optionally filtered."
  (let* ((filter-clause (if (null? search-terms)
                            ""
                            (build-text-filter "?text" search-terms)))
         (sparql (format #f "
PREFIX locomo: <~a>
SELECT ?text ?date ?speaker ?sessionIdx
FROM <~a>
WHERE {
  ?evt a locomo:Event ;
       locomo:text ?text ;
       locomo:occursIn ?session .
  ?session locomo:sessionIndex ?sessionIdx .
  ?agent locomo:experienced ?evt ;
         locomo:name ?speaker .
  OPTIONAL { ?evt locomo:date ?date }
  ~a
}
ORDER BY ?sessionIdx" locomo-ns graph-uri filter-clause))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (b)
           `((type . event)
             (text . ,(binding-value b "text"))
             (date . ,(binding-value b "date"))
             (speaker . ,(binding-value b "speaker"))
             (sessionIdx . ,(binding-value b "sessionIdx"))))
         bindings)))

;;; --------------------------------------------------------------------
;;; Hybrid Retrieval (SPARQL + ranking)
;;; --------------------------------------------------------------------

(define (retrieve-hybrid store graph-uri question max-tokens)
  "Combine multiple retrieval strategies and rank results.
   Uses observations (high signal) + events + matching utterances."
  (let* ((search-terms (extract-search-terms question))
         (entities (extract-entities question))
         ;; Get observations (highest priority - pre-extracted knowledge)
         (observations (query-all-observations store graph-uri search-terms))
         ;; Get events (good for temporal questions)
         (events (query-all-events store graph-uri search-terms))
         ;; Get matching utterances
         (utterances (query-matching-utterances store graph-uri search-terms))
         ;; Combine with observations first (they're distilled knowledge)
         (ranked-context (append observations events utterances))
         (context-str (format-context-for-llm ranked-context max-tokens)))
    `((context . ,context-str)
      (metadata . ((strategy . hybrid)
                   (search_terms . ,search-terms)
                   (entities . ,entities)
                   (observations . ,(length observations))
                   (events . ,(length events))
                   (utterances . ,(length utterances)))))))

;;; --------------------------------------------------------------------
;;; Entity Extraction (Simple heuristic-based)
;;; --------------------------------------------------------------------

(define (extract-entities question)
  "Extract potential entity names from a question.
   Returns list of capitalized words that might be names."
  (let* ((words (string-split question #\space))
         (capitalized (filter (lambda (w)
                                (and (> (string-length w) 1)
                                     (char-upper-case? (string-ref w 0))
                                     (not (question-word? w))))
                              words)))
    ;; Clean punctuation
    (map (lambda (w)
           (string-trim-right w (lambda (c)
                                  (member c '(#\? #\. #\, #\! #\' #\")))))
         capitalized)))

(define (question-word? word)
  "Check if word is a question word (not an entity)."
  (member (string-downcase word)
          '("what" "when" "where" "who" "why" "how" "which"
            "is" "are" "was" "were" "does" "did" "do"
            "would" "could" "should" "can" "will"
            "the" "a" "an")))

(define (extract-search-terms question)
  "Extract meaningful search terms from question.
   Filters out stop words and question words."
  (let* ((words (string-split question #\space))
         (cleaned (map (lambda (w)
                         (string-trim-right
                          (string-trim w)
                          (lambda (c) (member c '(#\? #\. #\, #\! #\' #\")))))
                       words))
         (filtered (filter (lambda (w)
                             (and (> (string-length w) 2)
                                  (not (stop-word? w))))
                           cleaned)))
    ;; Return lowercased terms
    (map string-downcase filtered)))

(define (stop-word? word)
  "Check if word is a stop word."
  (member (string-downcase word)
          '("the" "a" "an" "is" "are" "was" "were" "be" "been" "being"
            "have" "has" "had" "do" "does" "did" "will" "would" "could"
            "should" "can" "may" "might" "must" "shall"
            "i" "you" "he" "she" "it" "we" "they" "me" "him" "her"
            "what" "when" "where" "who" "why" "how" "which"
            "this" "that" "these" "those"
            "and" "or" "but" "if" "then" "else"
            "for" "with" "to" "from" "in" "on" "at" "by" "of"
            "not" "no" "yes")))

;;; --------------------------------------------------------------------
;;; SPARQL Filter Builders
;;; --------------------------------------------------------------------

(define (build-text-filter var terms)
  "Build SPARQL FILTER clause for text matching."
  (if (null? terms)
      ""
      (string-append
       "FILTER("
       (string-join
        (map (lambda (term)
               (format #f "CONTAINS(LCASE(~a), \"~a\")" var (escape-sparql term)))
             terms)
        " || ")
       ")")))

(define (build-name-filter names)
  "Build SPARQL FILTER for matching speaker names."
  (if (null? names)
      ""
      (string-append
       "FILTER(?speaker IN ("
       (string-join
        (map (lambda (n) (format #f "\"~a\"" (escape-sparql n))) names)
        ", ")
       "))")))

(define (escape-sparql str)
  "Escape special characters for SPARQL string literals."
  (string-map (lambda (c)
                (case c
                  ((#\") #\')
                  ((#\\) #\/)
                  (else c)))
              str))

;;; --------------------------------------------------------------------
;;; Context Formatting
;;; --------------------------------------------------------------------

(define (format-context-for-llm items max-tokens)
  "Format retrieved items into a string for LLM consumption.
   Truncates to approximately MAX-TOKENS tokens."
  (let* ((formatted (map format-context-item items))
         (joined (string-join formatted "\n\n")))
    ;; Simple truncation (approximate tokens as chars/4)
    (if (> (string-length joined) (* max-tokens 4))
        (substring joined 0 (* max-tokens 4))
        joined)))

(define (format-context-item item)
  "Format a single context item as readable text."
  (let ((type (assoc-ref item 'type))
        (text (or (assoc-ref item 'text) ""))
        (speaker (or (assoc-ref item 'speaker) "Unknown"))
        (dia-id (or (assoc-ref item 'diaId) ""))
        (date (or (assoc-ref item 'date) ""))
        (session-idx (or (assoc-ref item 'sessionIdx) "")))
    (case type
      ((utterance)
       (format #f "[~a] ~a: \"~a\"" dia-id speaker text))
      ((observation)
       (format #f "[Observation/~a, Session ~a] ~a" speaker session-idx text))
      ((event)
       (if (and date (> (string-length date) 0))
           (format #f "[Event/~a, ~a] ~a" speaker date text)
           (format #f "[Event/~a, Session ~a] ~a" speaker session-idx text)))
      ((dialog-chain)
       (format #f "[~a] ~a: \"~a\"" dia-id speaker text))
      (else
       (format #f "[~a] ~a" type text)))))

;;; --------------------------------------------------------------------
;;; SPARQL Result Helpers
;;; --------------------------------------------------------------------

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
