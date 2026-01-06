;;; eval/locomo/llm-eval.scm --- LLM-based answer generation for LoCoMo
;;;
;;; This module shows how to plug in an LLM for full F1 evaluation.
;;; Replace the generate-answer function with your preferred LLM API.

(define-module (eval locomo llm-eval)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (xm store)
  #:use-module (eval locomo ingest)
  #:use-module (eval locomo retrieve)
  #:use-module (eval locomo evaluate)
  #:use-module (eval locomo conditions)
  #:export (run-llm-evaluation
            generate-answer-claude
            generate-answer-stub))

;;; --------------------------------------------------------------------
;;; LLM Answer Generation
;;; --------------------------------------------------------------------

(define (generate-answer-claude question context)
  "Generate an answer using Claude API via curl.
   Requires ANTHROPIC_API_KEY environment variable."
  (let* ((api-key (getenv "ANTHROPIC_API_KEY"))
         (prompt (format #f "Based on the following context, answer the question concisely.

Context:
~a

Question: ~a

Answer (be brief and direct):" context question)))
    (if (not api-key)
        (begin
          (format (current-error-port) "Warning: ANTHROPIC_API_KEY not set~%")
          "")
        ;; Call Claude API
        (let* ((escaped-prompt (escape-json prompt))
               (cmd (format #f "curl -s https://api.anthropic.com/v1/messages \
                 -H 'Content-Type: application/json' \
                 -H 'x-api-key: ~a' \
                 -H 'anthropic-version: 2023-06-01' \
                 -d '{\"model\": \"claude-3-haiku-20240307\", \"max_tokens\": 100, \"messages\": [{\"role\": \"user\", \"content\": \"~a\"}]}'"
                            api-key escaped-prompt))
               (port (open-input-pipe cmd))
               (response (read-string port)))
          (close-pipe port)
          ;; Extract text from response (simple parsing)
          (extract-claude-response response)))))

(define (escape-json str)
  "Escape string for JSON."
  (let ((result '()))
    (string-for-each
     (lambda (c)
       (set! result
             (cons (case c
                     ((#\") "\\\"")
                     ((#\\) "\\\\")
                     ((#\newline) "\\n")
                     ((#\tab) "\\t")
                     ((#\return) "")
                     (else (string c)))
                   result)))
     str)
    (apply string-append (reverse result))))

(define (extract-claude-response json-str)
  "Extract text content from Claude API response."
  ;; Simple extraction - looks for "text":" and extracts until next "
  (let ((start (string-contains json-str "\"text\":\"")))
    (if start
        (let* ((text-start (+ start 8))
               (text-end (string-index json-str #\" text-start)))
          (if text-end
              (substring json-str text-start text-end)
              ""))
        "")))

(define (generate-answer-stub question context)
  "Stub answer generator - returns first sentence from context.
   Use for testing without LLM API."
  (let ((lines (string-split context #\newline)))
    (if (null? lines)
        ""
        (let ((first-line (car (filter (lambda (l) (> (string-length l) 10)) lines))))
          (if first-line
              (substring first-line 0 (min 100 (string-length first-line)))
              "")))))

;;; --------------------------------------------------------------------
;;; Full LLM Evaluation Runner
;;; --------------------------------------------------------------------

(define* (run-llm-evaluation #:key
                              (data-path "eval/locomo/data/locomo10.json")
                              (condition 'xm-sparql)
                              (qa-limit 10)
                              (use-llm #f)
                              (verbose #t))
  "Run full LoCoMo evaluation with LLM answer generation.

   Set use-llm to #t and ensure ANTHROPIC_API_KEY is set for real evaluation."

  (define (get-string-all port)
    (let loop ((chars '()))
      (let ((c (read-char port)))
        (if (eof-object? c)
            (list->string (reverse chars))
            (loop (cons c chars))))))

  ;; Load data
  (when verbose (format #t "Loading dataset...~%"))
  (let* ((json-str (call-with-input-file data-path get-string-all))
         (conversations (json-string->scm json-str))
         (conv (car conversations))
         (conv-id (assoc-ref conv "sample_id"))
         (store (make-memory-store)))

    ;; Ingest
    (when verbose (format #t "Ingesting conversation ~a...~%" conv-id))
    (ingest-conversation store conv)

    ;; Create retriever and answer generator
    (let* ((retriever (make-retriever condition))
           (answer-fn (if use-llm
                          generate-answer-claude
                          generate-answer-stub))
           (qa-pairs (take (assoc-ref conv "qa") qa-limit)))

      (when verbose
        (format #t "Evaluating ~a questions with ~a...~%"
                qa-limit (if use-llm "Claude API" "stub generator")))

      ;; Run evaluation
      (let ((result (evaluate-conversation
                     store conv retriever
                     #:limit qa-limit
                     #:generate-answer-fn answer-fn
                     #:verbose verbose)))

        (store-close store)

        ;; Print results
        (format #t "~%~a~%" (format-results result #:format 'summary))
        result))))

;;; --------------------------------------------------------------------
;;; Quick Test
;;; --------------------------------------------------------------------

(define (test-llm-eval)
  "Quick test of LLM evaluation."
  (run-llm-evaluation #:qa-limit 5 #:use-llm #f #:verbose #t))
