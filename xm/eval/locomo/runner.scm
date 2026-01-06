;;; eval/locomo/runner.scm --- Main runner for LoCoMo evaluation
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module provides the main entry point for running LoCoMo evaluations,
;;; coordinating ingestion, retrieval, and scoring across conditions.

(define-module (eval locomo runner)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (ice-9 getopt-long)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (xm store)
  #:use-module (eval locomo ingest)
  #:use-module (eval locomo retrieve)
  #:use-module (eval locomo evaluate)
  #:use-module (eval locomo conditions)
  #:export (run-locomo-eval
            run-ingest
            run-evaluate
            run-compare
            run-quick-test
            locomo-main))

;;; --------------------------------------------------------------------
;;; Configuration
;;; --------------------------------------------------------------------

(define *default-data-path* "eval/locomo/data/locomo10.json")
(define *default-results-path* "eval/locomo/results")

;;; --------------------------------------------------------------------
;;; Main Runner
;;; --------------------------------------------------------------------

(define* (run-locomo-eval #:key
                          (data-path *default-data-path*)
                          (store-path #f)
                          (conditions '(xm-hybrid))
                          (conversation-ids #f)
                          (categories #f)
                          (qa-limit #f)
                          (max-tokens 4000)
                          (output-format 'summary)
                          (verbose #f))
  "Run the full LoCoMo evaluation.

   Arguments:
   - data-path: Path to locomo10.json
   - store-path: Path to xm store (default: in-memory)
   - conditions: List of condition symbols to evaluate
   - conversation-ids: List of conv IDs to evaluate (default: all)
   - categories: List of QA categories (1-5) to evaluate
   - qa-limit: Max QA pairs per conversation
   - max-tokens: Max context tokens per retrieval
   - output-format: 'summary, 'detailed, or 'json
   - verbose: Print progress"

  ;; Load dataset
  (when verbose
    (format #t "Loading LoCoMo dataset from ~a...~%" data-path))

  (let* ((json-str (call-with-input-file data-path get-string-all))
         (conversations (json-string->scm json-str))
         ;; Filter conversations if specified
         (selected-convs (if conversation-ids
                             (filter (lambda (c)
                                       (member (assoc-ref c "sample_id")
                                               conversation-ids))
                                     conversations)
                             conversations)))

    (when verbose
      (format #t "Loaded ~a conversations~%" (length selected-convs))
      (format #t "Conditions to evaluate: ~a~%" conditions))

    ;; Open store
    (let ((store (if store-path
                     (make-store store-path)
                     (make-memory-store))))

      ;; Run each condition
      (let ((all-results
             (map (lambda (condition)
                    (when verbose
                      (format #t "~%=== Running condition: ~a ===~%" condition))

                    (let ((result (run-single-condition
                                   store selected-convs condition
                                   #:categories categories
                                   #:qa-limit qa-limit
                                   #:max-tokens max-tokens
                                   #:verbose verbose)))
                      (cons condition result)))
                  conditions)))

        ;; Close store
        (store-close store)

        ;; Format and return results
        (format-comparison-results all-results output-format)))))

;;; --------------------------------------------------------------------
;;; Single Condition Runner
;;; --------------------------------------------------------------------

(define* (run-single-condition store conversations condition
                                #:key
                                (categories #f)
                                (qa-limit #f)
                                (max-tokens 4000)
                                (verbose #f))
  "Run evaluation for a single condition across conversations."

  ;; First, ingest all conversations
  (when verbose
    (format #t "Ingesting conversations...~%"))

  (for-each (lambda (conv)
              (ingest-conversation store conv #:verbose verbose))
            conversations)

  ;; Create retriever for this condition
  (let ((retriever (make-retriever condition #:max-tokens max-tokens)))

    ;; Evaluate
    (evaluate-all store conversations retriever
                  #:categories categories
                  #:qa-limit qa-limit
                  #:verbose verbose)))

;;; --------------------------------------------------------------------
;;; Convenience Commands
;;; --------------------------------------------------------------------

(define* (run-ingest #:key
                     (data-path *default-data-path*)
                     (store-path #f)
                     (conversation-ids #f)
                     (verbose #f))
  "Ingest LoCoMo conversations into xm store."
  (let* ((json-str (call-with-input-file data-path get-string-all))
         (conversations (json-string->scm json-str))
         (selected-convs (if conversation-ids
                             (filter (lambda (c)
                                       (member (assoc-ref c "sample_id")
                                               conversation-ids))
                                     conversations)
                             conversations))
         (store (if store-path
                    (make-store store-path)
                    (make-memory-store))))

    (when verbose
      (format #t "Ingesting ~a conversations...~%" (length selected-convs)))

    (let ((ids (map (lambda (conv)
                      (ingest-conversation store conv #:verbose verbose))
                    selected-convs)))

      (store-close store)

      `((ingested . ,ids)
        (count . ,(length ids))))))

(define* (run-evaluate #:key
                       (data-path *default-data-path*)
                       (store-path #f)
                       (condition 'xm-hybrid)
                       (conversation-id #f)
                       (categories #f)
                       (qa-limit #f)
                       (verbose #f))
  "Run evaluation for a single condition."
  (run-locomo-eval #:data-path data-path
                   #:store-path store-path
                   #:conditions (list condition)
                   #:conversation-ids (and conversation-id (list conversation-id))
                   #:categories categories
                   #:qa-limit qa-limit
                   #:verbose verbose))

(define* (run-compare #:key
                      (data-path *default-data-path*)
                      (store-path #f)
                      (conditions '(baseline-raw xm-sparql xm-hybrid))
                      (conversation-ids #f)
                      (categories #f)
                      (qa-limit 50)
                      (verbose #f))
  "Compare multiple conditions side-by-side."
  (run-locomo-eval #:data-path data-path
                   #:store-path store-path
                   #:conditions conditions
                   #:conversation-ids conversation-ids
                   #:categories categories
                   #:qa-limit qa-limit
                   #:output-format 'detailed
                   #:verbose verbose))

(define* (run-quick-test #:key
                         (data-path *default-data-path*)
                         (verbose #t))
  "Run a quick sanity test with minimal data."
  (format #t "~%=== LoCoMo Quick Test ===~%~%")

  (run-locomo-eval #:data-path data-path
                   #:conditions '(xm-hybrid)
                   #:conversation-ids '("conv-26")  ; First conversation
                   #:categories '(1 2)  ; single_hop and temporal only
                   #:qa-limit 10
                   #:verbose verbose))

;;; --------------------------------------------------------------------
;;; Result Formatting
;;; --------------------------------------------------------------------

(define (format-comparison-results results format-type)
  "Format results comparing multiple conditions."
  (case format-type
    ((summary)
     (with-output-to-string
       (lambda ()
         (format #t "~%=== LoCoMo Evaluation Comparison ===~%~%")
         (format #t "~20a ~10a ~10a ~10a ~10a~%"
                 "Condition" "F1" "Multi-hop" "Temporal" "Efficiency")
         (format #t "~a~%" (make-string 60 #\-))

         (for-each
          (lambda (cond-result)
            (let* ((condition (car cond-result))
                   (result (cdr cond-result))
                   (metrics (assoc-ref result 'aggregate_metrics))
                   (overall-f1 (assoc-ref metrics 'overall_f1))
                   (by-cat (assoc-ref metrics 'by_category))
                   (multi-hop-f1 (get-category-f1 by-cat 'multi_hop))
                   (temporal-f1 (get-category-f1 by-cat 'temporal))
                   (efficiency (assoc-ref metrics 'context_efficiency)))
              (format #t "~20a ~10,3f ~10,3f ~10,3f ~10,3f~%"
                      condition
                      (or overall-f1 0)
                      (or multi-hop-f1 0)
                      (or temporal-f1 0)
                      (or efficiency 0))))
          results)

         (format #t "~%Legend: F1 = overall token F1, Efficiency = F1 per 1k context chars~%"))))

    ((detailed)
     (apply string-append
            (map (lambda (cond-result)
                   (format #f "~%### Condition: ~a ###~%~a"
                           (car cond-result)
                           (format-results (cdr cond-result) #:format 'detailed)))
                 results)))

    ((json)
     (scm->json-string
      (map (lambda (cr)
             `((condition . ,(car cr))
               (results . ,(cdr cr))))
           results)))

    (else
     (format-comparison-results results 'summary))))

(define (get-category-f1 by-category category-name)
  "Extract F1 for a specific category."
  (let ((cat-result (assoc category-name by-category)))
    (if cat-result
        (assoc-ref (cdr cat-result) 'f1)
        #f)))

;;; --------------------------------------------------------------------
;;; CLI Entry Point
;;; --------------------------------------------------------------------

(define (locomo-main args)
  "Main entry point for locomo eval CLI.

   Usage:
     locomo-eval ingest [--conversation ID]
     locomo-eval run [--condition COND] [--conversation ID] [--category N]
     locomo-eval compare [--conditions C1,C2,...]
     locomo-eval quick-test"

  (let* ((option-spec '((help (single-char #\h))
                        (verbose (single-char #\v))
                        (data-path (single-char #\d) (value #t))
                        (store-path (single-char #\s) (value #t))
                        (condition (single-char #\c) (value #t))
                        (conditions (value #t))
                        (conversation (value #t))
                        (category (value #t))
                        (limit (single-char #\l) (value #t))
                        (format (single-char #\f) (value #t))))
         (options (getopt-long args option-spec))
         (command (option-ref options '() '()))
         (help? (option-ref options 'help #f))
         (verbose? (option-ref options 'verbose #f)))

    (cond
     (help?
      (display-help))

     ((null? command)
      (display-help)
      (exit 1))

     (else
      (let ((cmd (string->symbol (car command))))
        (case cmd
          ((ingest)
           (run-ingest #:data-path (option-ref options 'data-path
                                               *default-data-path*)
                       #:store-path (option-ref options 'store-path #f)
                       #:conversation-ids (parse-list-option
                                           (option-ref options 'conversation #f))
                       #:verbose verbose?))

          ((run evaluate)
           (run-evaluate #:data-path (option-ref options 'data-path
                                                 *default-data-path*)
                         #:store-path (option-ref options 'store-path #f)
                         #:condition (string->symbol
                                      (option-ref options 'condition "xm-hybrid"))
                         #:conversation-id (option-ref options 'conversation #f)
                         #:categories (parse-int-list-option
                                       (option-ref options 'category #f))
                         #:qa-limit (string->number
                                     (option-ref options 'limit "0"))
                         #:verbose verbose?))

          ((compare)
           (run-compare #:data-path (option-ref options 'data-path
                                                *default-data-path*)
                        #:store-path (option-ref options 'store-path #f)
                        #:conditions (parse-symbol-list-option
                                      (option-ref options 'conditions
                                                  "baseline-raw,xm-sparql,xm-hybrid"))
                        #:conversation-ids (parse-list-option
                                            (option-ref options 'conversation #f))
                        #:categories (parse-int-list-option
                                      (option-ref options 'category #f))
                        #:qa-limit (let ((l (option-ref options 'limit #f)))
                                     (and l (string->number l)))
                        #:verbose verbose?))

          ((quick-test test)
           (run-quick-test #:data-path (option-ref options 'data-path
                                                   *default-data-path*)
                           #:verbose verbose?))

          (else
           (format (current-error-port) "Unknown command: ~a~%" cmd)
           (exit 1))))))))

(define (display-help)
  (display "
LoCoMo Evaluation Runner

Usage:
  locomo-eval <command> [options]

Commands:
  ingest      Ingest LoCoMo conversations into xm store
  run         Run evaluation with a single condition
  compare     Compare multiple conditions side-by-side
  quick-test  Run a quick sanity test

Options:
  -h, --help              Show this help
  -v, --verbose           Verbose output
  -d, --data-path PATH    Path to locomo10.json
  -s, --store-path PATH   Path to persistent xm store
  -c, --condition COND    Retrieval condition (default: xm-hybrid)
  --conditions C1,C2,...  Comma-separated conditions for compare
  --conversation ID       Specific conversation ID(s)
  --category N            QA category number(s) (1-5)
  -l, --limit N           Max QA pairs per conversation
  -f, --format FMT        Output format: summary, detailed, json

Conditions:
  xm-sparql      SPARQL text search
  xm-backlinks   Entity-based backlink traversal
  xm-path        Path queries for multi-hop
  xm-observations Pre-extracted observations
  xm-events      Event summaries (temporal)
  xm-hybrid      Combined strategies (recommended)
  baseline-raw   Raw dialog (control)
  baseline-obs   Observations without graph

Examples:
  locomo-eval quick-test
  locomo-eval run --condition xm-hybrid --verbose
  locomo-eval compare --conditions baseline-raw,xm-hybrid --limit 20
  locomo-eval run --category 2,4 --verbose  # temporal and multi-hop only
"))

;;; --------------------------------------------------------------------
;;; Option Parsing Helpers
;;; --------------------------------------------------------------------

(define (parse-list-option opt)
  "Parse comma-separated list option."
  (and opt (string-split opt #\,)))

(define (parse-int-list-option opt)
  "Parse comma-separated integer list."
  (and opt
       (filter identity
               (map string->number (string-split opt #\,)))))

(define (parse-symbol-list-option opt)
  "Parse comma-separated symbol list."
  (and opt
       (map string->symbol (string-split opt #\,))))

(define (get-string-all port)
  "Read all remaining characters from PORT."
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define (scm->json-string obj)
  "Simple JSON serialization."
  (cond
   ((null? obj) "null")
   ((boolean? obj) (if obj "true" "false"))
   ((number? obj) (number->string obj))
   ((string? obj) (format #f "\"~a\"" obj))
   ((symbol? obj) (format #f "\"~a\"" (symbol->string obj)))
   ((pair? obj)
    (if (and (pair? (car obj)) (not (list? (car obj))))
        (string-append "{"
                       (string-join
                        (map (lambda (kv)
                               (format #f "\"~a\":~a"
                                       (if (symbol? (car kv))
                                           (symbol->string (car kv))
                                           (car kv))
                                       (scm->json-string (cdr kv))))
                             obj)
                        ",")
                       "}")
        (string-append "["
                       (string-join (map scm->json-string obj) ",")
                       "]")))
   (else (format #f "\"~a\"" obj))))
