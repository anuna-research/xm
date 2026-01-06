;;; eval/locomo/llm-judge.scm --- LLM Judge evaluation for LoCoMo
;;;
;;; Following the Memobase evaluation methodology:
;;; 1. Retrieve context using memory system
;;; 2. Generate answer using LLM with context
;;; 3. Judge correctness using LLM (binary: correct/wrong)
;;;
;;; Run with: ./bin/xm eval locomo llm-judge --condition xm-sparql

(define-module (eval locomo llm-judge)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (xm store)
  #:use-module (eval locomo ingest)
  #:use-module (eval locomo retrieve)
  #:use-module (eval locomo conditions)
  #:export (run-llm-judge-eval
            llm-generate-answer
            llm-judge-answer
            *answer-prompt*
            *judge-prompt*))

;;; --------------------------------------------------------------------
;;; Prompts (following Memobase methodology)
;;; --------------------------------------------------------------------

(define *answer-prompt*
  "Based on the following conversation context, answer the question concisely.
If the answer cannot be determined from the context, say \"Cannot determine\".

Context:
~a

Question: ~a

Answer:")

(define *judge-prompt*
  "You are evaluating a question-answering system's response against a gold standard answer.

Question: ~a
Gold Answer: ~a
Generated Answer: ~a

Instructions:
- Label as 'CORRECT' if the generated answer conveys the same essential information as the gold answer
- Be generous: as long as it touches on the same topic/meaning, count it as CORRECT
- For time-related answers, flexible matching is acceptable (e.g., \"May 2023\" vs \"7 May 2023\")
- Label as 'WRONG' only if the answer is factually different or completely misses the point

Respond with exactly one word: CORRECT or WRONG")

;;; --------------------------------------------------------------------
;;; LLM API Calls
;;; --------------------------------------------------------------------

(define* (call-claude prompt #:key (model "claude-3-haiku-20240307") (max-tokens 200))
  "Call Claude API with prompt. Requires ANTHROPIC_API_KEY env var."
  (let ((api-key (getenv "ANTHROPIC_API_KEY")))
    (if (not api-key)
        (error "ANTHROPIC_API_KEY environment variable not set")
        (let* ((escaped-prompt (escape-json prompt))
               (cmd (format #f "curl -s 'https://api.anthropic.com/v1/messages' \
                 -H 'Content-Type: application/json' \
                 -H 'x-api-key: ~a' \
                 -H 'anthropic-version: 2023-06-01' \
                 -d '{\"model\": \"~a\", \"max_tokens\": ~a, \"messages\": [{\"role\": \"user\", \"content\": \"~a\"}]}'"
                            api-key model max-tokens escaped-prompt))
               (port (open-input-pipe cmd))
               (response (read-string port)))
          (close-pipe port)
          (extract-text-from-response response)))))

(define (escape-json str)
  "Escape string for JSON embedding."
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

(define (extract-text-from-response json-str)
  "Extract text content from Claude API JSON response."
  (let ((match (string-match "\"text\"[[:space:]]*:[[:space:]]*\"([^\"]+)\"" json-str)))
    (if match
        (match:substring match 1)
        "")))

(define (read-string port)
  "Read all content from port as string."
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

;;; --------------------------------------------------------------------
;;; Answer Generation and Judging
;;; --------------------------------------------------------------------

(define (llm-generate-answer question context)
  "Generate an answer to the question given the context."
  (let ((prompt (format #f *answer-prompt*
                        (truncate-context context 6000)
                        question)))
    (call-claude prompt #:max-tokens 150)))

(define (llm-judge-answer question gold-answer generated-answer)
  "Judge if generated answer matches gold answer. Returns 1 or 0."
  (let* ((prompt (format #f *judge-prompt* question gold-answer generated-answer))
         (response (call-claude prompt #:max-tokens 10)))
    (if (string-contains (string-upcase response) "CORRECT")
        1
        0)))

(define (truncate-context context max-chars)
  "Truncate context to max characters."
  (if (> (string-length context) max-chars)
      (substring context 0 max-chars)
      context))

;;; --------------------------------------------------------------------
;;; Main Evaluation Runner
;;; --------------------------------------------------------------------

(define* (run-llm-judge-eval #:key
                              (data-path "eval/locomo/data/locomo10.json")
                              (condition 'xm-sparql)
                              (qa-limit 20)
                              (skip-category-5 #t)
                              (verbose #t))
  "Run full LLM-judged evaluation on LoCoMo.

   Arguments:
   - condition: Memory retrieval method to evaluate
   - qa-limit: Max questions to evaluate (for cost control)
   - skip-category-5: Skip adversarial questions (standard practice)
   - verbose: Print progress"

  (define (get-string-all port)
    (let loop ((chars '()))
      (let ((c (read-char port)))
        (if (eof-object? c)
            (list->string (reverse chars))
            (loop (cons c chars))))))

  (define category-names
    '((1 . "single_hop") (2 . "temporal") (3 . "commonsense")
      (4 . "multi_hop") (5 . "adversarial")))

  ;; Load data
  (when verbose (format #t "~%=== LoCoMo LLM Judge Evaluation ===~%~%"))
  (when verbose (format #t "Loading dataset...~%"))

  (let* ((json-str (call-with-input-file data-path get-string-all))
         (conversations (json-string->scm json-str))
         (conv (car conversations))
         (conv-id (assoc-ref conv "sample_id"))
         (store (make-memory-store)))

    ;; Ingest
    (when verbose (format #t "Ingesting conversation ~a...~%" conv-id))
    (ingest-conversation store conv)

    ;; Filter and limit QA pairs
    (let* ((all-qa (assoc-ref conv "qa"))
           (filtered-qa (if skip-category-5
                            (filter (lambda (qa)
                                     (not (= (assoc-ref qa "category") 5)))
                                   all-qa)
                            all-qa))
           (test-qa (take filtered-qa (min qa-limit (length filtered-qa))))
           (retriever (make-retriever condition #:max-tokens 4000)))

      (when verbose
        (format #t "Evaluating ~a questions with condition: ~a~%~%"
                (length test-qa) condition))

      ;; Run evaluation
      (let ((results
             (let loop ((qas test-qa) (idx 1) (results '()))
               (if (null? qas)
                   (reverse results)
                   (let* ((qa (car qas))
                          (question (assoc-ref qa "question"))
                          (gold-answer (let ((ans (assoc-ref qa "answer")))
                                        (if (string? ans) ans (format #f "~a" ans))))
                          (category (assoc-ref qa "category"))
                          ;; Retrieve context
                          (ctx-result (retriever store conv-id question))
                          (context (assoc-ref ctx-result 'context))
                          ;; Generate answer
                          (_ (when verbose
                               (format #t "[~a/~a] Q: ~a~%" idx (length test-qa)
                                       (if (> (string-length question) 50)
                                           (string-append (substring question 0 50) "...")
                                           question))))
                          (generated (llm-generate-answer question context))
                          ;; Judge
                          (score (llm-judge-answer question gold-answer generated)))

                     (when verbose
                       (format #t "        Gold: ~a~%"
                               (if (> (string-length gold-answer) 40)
                                   (string-append (substring gold-answer 0 40) "...")
                                   gold-answer))
                       (format #t "        Got:  ~a~%"
                               (if (> (string-length generated) 40)
                                   (string-append (substring generated 0 40) "...")
                                   generated))
                       (format #t "        Score: ~a~%~%" (if (= score 1) "✓ CORRECT" "✗ WRONG")))

                     (loop (cdr qas) (+ idx 1)
                           (cons (list category score) results)))))))

        (store-close store)

        ;; Compute metrics by category
        (let* ((by-category
                (map (lambda (cat-num)
                       (let* ((cat-results (filter (lambda (r) (= (car r) cat-num)) results))
                              (cat-scores (map cadr cat-results))
                              (accuracy (if (null? cat-scores)
                                           0.0
                                           (/ (apply + cat-scores) (length cat-scores)))))
                         (cons cat-num
                               `((name . ,(assoc-ref category-names cat-num))
                                 (count . ,(length cat-scores))
                                 (correct . ,(apply + cat-scores))
                                 (accuracy . ,accuracy)))))
                     '(1 2 3 4)))
               (overall-scores (map cadr results))
               (overall-accuracy (/ (apply + overall-scores) (length overall-scores))))

          ;; Print results
          (format #t "~%╔════════════════════════════════════════════════════════════╗~%")
          (format #t "║              LLM Judge Results: ~a               ║~%" condition)
          (format #t "╠════════════════════════════════════════════════════════════╣~%")
          (format #t "║ Category       │ Correct │ Total │ Accuracy              ║~%")
          (format #t "╠════════════════════════════════════════════════════════════╣~%")

          (for-each
           (lambda (cat-result)
             (let* ((cat-data (cdr cat-result))
                    (name (assoc-ref cat-data 'name))
                    (correct (assoc-ref cat-data 'correct))
                    (count (assoc-ref cat-data 'count))
                    (accuracy (assoc-ref cat-data 'accuracy)))
               (when (> count 0)
                 (format #t "║ ~14a │ ~7a │ ~5a │ ~6,1f%                ║~%"
                         name correct count (* 100 accuracy)))))
           by-category)

          (format #t "╠════════════════════════════════════════════════════════════╣~%")
          (format #t "║ OVERALL        │ ~7a │ ~5a │ ~6,1f%                ║~%"
                  (apply + overall-scores) (length overall-scores) (* 100 overall-accuracy))
          (format #t "╚════════════════════════════════════════════════════════════╝~%")

          ;; Return results
          `((condition . ,condition)
            (total . ,(length results))
            (overall_accuracy . ,overall-accuracy)
            (by_category . ,by-category)))))))

;;; --------------------------------------------------------------------
;;; Comparison Runner
;;; --------------------------------------------------------------------

(define* (compare-conditions #:key
                              (conditions '(baseline-raw xm-sparql xm-hybrid))
                              (qa-limit 20)
                              (verbose #f))
  "Compare multiple conditions using LLM judge."
  (format #t "~%=== Comparing Memory Conditions with LLM Judge ===~%~%")

  (let ((results
         (map (lambda (cond)
                (format #t "~%--- Evaluating ~a ---~%~%" cond)
                (run-llm-judge-eval #:condition cond
                                    #:qa-limit qa-limit
                                    #:verbose verbose))
              conditions)))

    ;; Summary comparison
    (format #t "~%~%=== COMPARISON SUMMARY ===~%~%")
    (format #t "┌─────────────────┬──────────────────────────────────────────────┐~%")
    (format #t "│ Condition       │ Single  Temporal  Multi   Common   OVERALL  │~%")
    (format #t "├─────────────────┼──────────────────────────────────────────────┤~%")

    (for-each
     (lambda (result)
       (let* ((condition (assoc-ref result 'condition))
              (by-cat (assoc-ref result 'by_category))
              (get-acc (lambda (cat-num)
                        (let ((cat (assoc cat-num by-cat)))
                          (if cat (* 100 (assoc-ref (cdr cat) 'accuracy)) 0))))
              (overall (* 100 (assoc-ref result 'overall_accuracy))))
         (format #t "│ ~15a │ ~5,1f%   ~5,1f%    ~5,1f%   ~5,1f%    ~5,1f%  │~%"
                 condition
                 (get-acc 1) (get-acc 2) (get-acc 4) (get-acc 3) overall)))
     results)

    (format #t "└─────────────────┴──────────────────────────────────────────────┘~%")
    results))
