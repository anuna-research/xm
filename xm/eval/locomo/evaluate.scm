;;; eval/locomo/evaluate.scm --- Evaluation scoring for LoCoMo benchmark
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements scoring metrics for the LoCoMo evaluation,
;;; including F1 score calculation and result aggregation.

(define-module (eval locomo evaluate)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (xm store)
  #:export (evaluate-qa
            evaluate-conversation
            evaluate-all
            compute-f1
            compute-token-f1
            compute-metrics
            format-results
            category-name
            *qa-categories*))

;;; --------------------------------------------------------------------
;;; QA Categories (from LoCoMo paper)
;;; --------------------------------------------------------------------

(define *qa-categories*
  '((1 . single_hop)
    (2 . temporal)
    (3 . commonsense)
    (4 . multi_hop)
    (5 . adversarial)))

(define (category-name cat-num)
  "Convert category number to name."
  (or (assoc-ref *qa-categories* cat-num)
      (string->symbol (format #f "category_~a" cat-num))))

;;; --------------------------------------------------------------------
;;; Token-level F1 Score (LoCoMo's primary metric)
;;; --------------------------------------------------------------------

(define (compute-token-f1 prediction ground-truth)
  "Compute token-level F1 score between prediction and ground truth.
   This is the main metric used in LoCoMo evaluation."
  (let* ((pred-tokens (tokenize prediction))
         (truth-tokens (tokenize ground-truth))
         (pred-set (list->set pred-tokens))
         (truth-set (list->set truth-tokens))
         (intersection (set-intersection pred-set truth-set))
         (precision (if (set-empty? pred-set)
                        0.0
                        (/ (set-size intersection) (set-size pred-set))))
         (recall (if (set-empty? truth-set)
                     0.0
                     (/ (set-size intersection) (set-size truth-set)))))
    (if (= (+ precision recall) 0)
        0.0
        (* 2 (/ (* precision recall) (+ precision recall))))))

(define (compute-f1 prediction ground-truth)
  "Alias for compute-token-f1 for compatibility."
  (compute-token-f1 prediction ground-truth))

(define (tokenize text)
  "Tokenize text into lowercase words."
  (if (string? text)
      (let* ((cleaned (string-downcase text))
             (words (string-split cleaned #\space)))
        (filter (lambda (w) (> (string-length w) 0))
                (map (lambda (w)
                       (string-trim-both
                        w
                        (lambda (c)
                          (member c '(#\. #\, #\! #\? #\' #\" #\( #\) #\[ #\])))))
                     words)))
      (if (number? text)
          (list (number->string text))
          '())))

;;; --------------------------------------------------------------------
;;; Simple Set Operations
;;; --------------------------------------------------------------------

(define (list->set lst)
  "Convert list to a set (unique elements)."
  (delete-duplicates lst equal?))

(define (set-intersection set1 set2)
  "Compute intersection of two sets (lists)."
  (filter (lambda (x) (member x set2 equal?)) set1))

(define (set-size set)
  "Return size of set."
  (length set))

(define (set-empty? set)
  "Check if set is empty."
  (null? set))

;;; --------------------------------------------------------------------
;;; Single QA Evaluation
;;; --------------------------------------------------------------------

(define* (evaluate-qa store conv-id qa retriever #:key (generate-answer-fn #f))
  "Evaluate a single QA pair.
   Returns an alist with question, prediction, ground truth, F1, etc.

   RETRIEVER is a procedure (retriever store conv-id question) -> context-result
   GENERATE-ANSWER-FN is optional; if not provided, uses context directly as prediction."
  (let* ((question (assoc-ref qa "question"))
         (ground-truth (assoc-ref qa "answer"))
         (category (assoc-ref qa "category"))
         (evidence (or (assoc-ref qa "evidence") '()))

         ;; Retrieve context
         (context-result (retriever store conv-id question))
         (context (assoc-ref context-result 'context))
         (retrieval-metadata (assoc-ref context-result 'metadata))

         ;; Generate answer (or use context if no LLM)
         (prediction (if generate-answer-fn
                         (generate-answer-fn question context)
                         (extract-answer-from-context context question)))

         ;; Compute F1
         (f1 (compute-token-f1 prediction
                               (if (string? ground-truth)
                                   ground-truth
                                   (format #f "~a" ground-truth))))

         ;; Check evidence overlap
         (evidence-in-context (compute-evidence-recall context evidence)))

    `((question . ,question)
      (category . ,category)
      (category_name . ,(category-name category))
      (ground_truth . ,ground-truth)
      (prediction . ,prediction)
      (f1 . ,f1)
      (context_length . ,(string-length context))
      (evidence . ,evidence)
      (evidence_recall . ,evidence-in-context)
      (retrieval_metadata . ,retrieval-metadata))))

(define (extract-answer-from-context context question)
  "Simple heuristic to extract an answer from context.
   For proper evaluation, this should be replaced with an LLM call."
  ;; Return first relevant sentence or observation
  (let ((lines (string-split context #\newline)))
    (if (null? lines)
        ""
        ;; Return the first non-empty line as a simple baseline
        (or (find (lambda (l) (> (string-length (string-trim l)) 10)) lines)
            ""))))

(define (compute-evidence-recall context evidence-refs)
  "Compute what fraction of evidence references appear in the context."
  (if (null? evidence-refs)
      1.0  ; No evidence required
      (let ((found (count (lambda (ref)
                            (string-contains context ref))
                          evidence-refs)))
        (/ found (length evidence-refs)))))

;;; --------------------------------------------------------------------
;;; Conversation-level Evaluation
;;; --------------------------------------------------------------------

(define* (evaluate-conversation store conv-data retriever
                                 #:key
                                 (categories #f)
                                 (limit #f)
                                 (generate-answer-fn #f)
                                 (verbose #f))
  "Evaluate all QA pairs in a conversation.
   CATEGORIES can be a list of category numbers to filter by.
   LIMIT restricts the number of QA pairs evaluated."
  (let* ((conv-id (assoc-ref conv-data "sample_id"))
         (qa-pairs (assoc-ref conv-data "qa"))
         ;; Filter by category if specified
         (filtered-qa (if categories
                          (filter (lambda (qa)
                                    (member (assoc-ref qa "category") categories))
                                  qa-pairs)
                          qa-pairs))
         ;; Apply limit
         (limited-qa (if (and limit (> (length filtered-qa) limit))
                         (take filtered-qa limit)
                         filtered-qa)))

    (when verbose
      (format #t "Evaluating ~a QA pairs for conversation ~a~%"
              (length limited-qa) conv-id))

    (let ((results (map (lambda (qa)
                          (when verbose
                            (format #t "  Q: ~a~%"
                                    (truncate-string (assoc-ref qa "question") 60)))
                          (evaluate-qa store conv-id qa retriever
                                       #:generate-answer-fn generate-answer-fn))
                        limited-qa)))

      ;; Compute aggregate metrics
      (let ((metrics (compute-metrics results)))
        `((conversation_id . ,conv-id)
          (total_qa . ,(length results))
          (results . ,results)
          (metrics . ,metrics))))))

;;; --------------------------------------------------------------------
;;; Full Evaluation (All Conversations)
;;; --------------------------------------------------------------------

(define* (evaluate-all store conversations retriever
                       #:key
                       (categories #f)
                       (conversation-limit #f)
                       (qa-limit #f)
                       (generate-answer-fn #f)
                       (verbose #f))
  "Evaluate across all conversations.
   Returns aggregated metrics and per-conversation results."
  (let* ((limited-convs (if (and conversation-limit
                                  (> (length conversations) conversation-limit))
                            (take conversations conversation-limit)
                            conversations))
         (conv-results (map (lambda (conv)
                              (evaluate-conversation
                               store conv retriever
                               #:categories categories
                               #:limit qa-limit
                               #:generate-answer-fn generate-answer-fn
                               #:verbose verbose))
                            limited-convs))
         ;; Flatten all individual results for aggregate metrics
         (all-results (apply append
                             (map (lambda (cr)
                                    (assoc-ref cr 'results))
                                  conv-results)))
         (aggregate-metrics (compute-metrics all-results)))

    `((total_conversations . ,(length limited-convs))
      (total_qa . ,(length all-results))
      (aggregate_metrics . ,aggregate-metrics)
      (per_conversation . ,conv-results))))

;;; --------------------------------------------------------------------
;;; Metrics Computation
;;; --------------------------------------------------------------------

(define (compute-metrics results)
  "Compute aggregate metrics from a list of QA results."
  (if (null? results)
      `((overall_f1 . 0.0)
        (by_category . ())
        (avg_context_length . 0)
        (avg_evidence_recall . 0.0))

      (let* ((f1-scores (map (lambda (r) (assoc-ref r 'f1)) results))
             (overall-f1 (mean f1-scores))
             ;; By category
             (by-category (compute-metrics-by-category results))
             ;; Context efficiency
             (context-lengths (map (lambda (r)
                                     (or (assoc-ref r 'context_length) 0))
                                   results))
             (avg-context-length (mean context-lengths))
             ;; Evidence recall
             (evidence-recalls (map (lambda (r)
                                      (or (assoc-ref r 'evidence_recall) 0))
                                    results))
             (avg-evidence-recall (mean evidence-recalls)))

        `((overall_f1 . ,overall-f1)
          (by_category . ,by-category)
          (avg_context_length . ,avg-context-length)
          (avg_evidence_recall . ,avg-evidence-recall)
          (context_efficiency . ,(if (> avg-context-length 0)
                                     (/ overall-f1 (/ avg-context-length 1000.0))
                                     0.0))))))

(define (compute-metrics-by-category results)
  "Group results by category and compute F1 for each."
  (let ((categories (delete-duplicates
                     (map (lambda (r) (assoc-ref r 'category)) results))))
    (map (lambda (cat)
           (let* ((cat-results (filter (lambda (r)
                                         (equal? (assoc-ref r 'category) cat))
                                       results))
                  (cat-f1s (map (lambda (r) (assoc-ref r 'f1)) cat-results)))
             (cons (category-name cat)
                   `((f1 . ,(mean cat-f1s))
                     (count . ,(length cat-results))))))
         categories)))

;;; --------------------------------------------------------------------
;;; Result Formatting
;;; --------------------------------------------------------------------

(define* (format-results eval-result #:key (format 'summary))
  "Format evaluation results for display.
   FORMAT is one of: 'summary, 'detailed, 'json"
  (case format
    ((summary)
     (format-summary eval-result))
    ((detailed)
     (format-detailed eval-result))
    ((json)
     (format-json eval-result))
    (else
     (format-summary eval-result))))

(define (format-summary eval-result)
  "Format a brief summary of results."
  (let* ((metrics (or (assoc-ref eval-result 'aggregate_metrics)
                      (assoc-ref eval-result 'metrics)))
         (overall-f1 (assoc-ref metrics 'overall_f1))
         (by-category (assoc-ref metrics 'by_category))
         (total-qa (assoc-ref eval-result 'total_qa)))

    (with-output-to-string
      (lambda ()
        (format #t "=== LoCoMo Evaluation Results ===~%~%")
        (format #t "Total QA pairs: ~a~%" total-qa)
        (format #t "Overall F1: ~,3f~%~%" overall-f1)
        (format #t "F1 by Category:~%")
        (for-each (lambda (cat-result)
                    (let ((cat-name (car cat-result))
                          (cat-f1 (assoc-ref (cdr cat-result) 'f1))
                          (cat-count (assoc-ref (cdr cat-result) 'count)))
                      (format #t "  ~a: ~,3f (n=~a)~%"
                              cat-name cat-f1 cat-count)))
                  by-category)
        (format #t "~%Avg context length: ~,0f chars~%"
                (assoc-ref metrics 'avg_context_length))
        (format #t "Avg evidence recall: ~,3f~%"
                (assoc-ref metrics 'avg_evidence_recall))
        (format #t "Context efficiency: ~,3f F1 per 1k chars~%"
                (assoc-ref metrics 'context_efficiency))))))

(define (format-detailed eval-result)
  "Format detailed results including per-question scores."
  (with-output-to-string
    (lambda ()
      (display (format-summary eval-result))
      (format #t "~%=== Per-Question Results ===~%~%")
      (let ((results (or (assoc-ref eval-result 'results)
                         (apply append
                                (map (lambda (cr) (assoc-ref cr 'results))
                                     (assoc-ref eval-result 'per_conversation))))))
        (for-each (lambda (r)
                    (format #t "Q: ~a~%" (truncate-string (assoc-ref r 'question) 70))
                    (format #t "   Category: ~a | F1: ~,3f | Evidence: ~,2f~%"
                            (assoc-ref r 'category_name)
                            (assoc-ref r 'f1)
                            (assoc-ref r 'evidence_recall))
                    (format #t "   Expected: ~a~%"
                            (truncate-string
                             (format #f "~a" (assoc-ref r 'ground_truth)) 60))
                    (format #t "   Got: ~a~%~%"
                            (truncate-string (assoc-ref r 'prediction) 60)))
                  results)))))

(define (format-json eval-result)
  "Format results as JSON string."
  (scm->json-string eval-result))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (mean lst)
  "Compute mean of a list of numbers."
  (if (null? lst)
      0.0
      (/ (apply + lst) (length lst))))

(define (truncate-string str max-len)
  "Truncate string to max-len, adding ... if truncated."
  (if (> (string-length str) max-len)
      (string-append (substring str 0 (- max-len 3)) "...")
      str))

(define (count pred lst)
  "Count elements in lst satisfying pred."
  (length (filter pred lst)))

;;; --------------------------------------------------------------------
;;; JSON Serialization (simple implementation)
;;; --------------------------------------------------------------------

(define (scm->json-string obj)
  "Convert Scheme object to JSON string."
  (cond
   ((null? obj) "null")
   ((boolean? obj) (if obj "true" "false"))
   ((number? obj) (number->string obj))
   ((string? obj) (format #f "\"~a\"" (escape-json-string obj)))
   ((symbol? obj) (format #f "\"~a\"" (symbol->string obj)))
   ((pair? obj)
    (if (and (pair? (car obj)) (not (list? (car obj))))
        ;; Alist -> JSON object
        (string-append
         "{"
         (string-join
          (map (lambda (kv)
                 (format #f "\"~a\": ~a"
                         (if (symbol? (car kv))
                             (symbol->string (car kv))
                             (car kv))
                         (scm->json-string (cdr kv))))
               obj)
          ", ")
         "}")
        ;; List -> JSON array
        (string-append
         "["
         (string-join (map scm->json-string obj) ", ")
         "]")))
   (else (format #f "\"~a\"" obj))))

(define (escape-json-string str)
  "Escape special characters in JSON string."
  (let ((result '()))
    (string-for-each
     (lambda (c)
       (set! result
             (cons (case c
                     ((#\") "\\\"")
                     ((#\\) "\\\\")
                     ((#\newline) "\\n")
                     ((#\tab) "\\t")
                     ((#\return) "\\r")
                     (else (string c)))
                   result)))
     str)
    (apply string-append (reverse result))))
