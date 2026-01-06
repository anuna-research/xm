#!/usr/bin/env -S guile -L guile -L eval/locomo -e main -s
!#
;;; eval/locomo/benchmark.scm --- LoCoMo LLM-judged benchmark
;;;
;;; Usage:
;;;   export ANTHROPIC_API_KEY=your_key
;;;   guile -L guile -L eval/locomo eval/locomo/benchmark.scm [condition] [limit]
;;;
;;; Example:
;;;   guile -L guile -L eval/locomo eval/locomo/benchmark.scm xm-sparql 20

(use-modules (ice-9 format)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 regex)
             (srfi srfi-1)
             (xm store)
             (eval locomo ingest)
             (eval locomo retrieve)
             (eval locomo conditions))

;;; --------------------------------------------------------------------
;;; Helpers
;;; --------------------------------------------------------------------

(define (get-string-all port)
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define (escape-for-shell str)
  "Escape string for shell command embedding."
  (regexp-substitute/global #f "['\"\\\\`$]"
                            str
                            'pre (lambda (m) (string-append "\\" (match:substring m))) 'post))

(define (call-claude-api prompt max-tokens)
  "Call Claude API and return response text."
  (let* ((api-key (getenv "ANTHROPIC_API_KEY"))
         (escaped-prompt (escape-for-shell prompt))
         ;; Build JSON payload manually to avoid escaping issues
         (payload (format #f "{\"model\":\"claude-3-haiku-20240307\",\"max_tokens\":~a,\"messages\":[{\"role\":\"user\",\"content\":\"~a\"}]}"
                          max-tokens escaped-prompt))
         (cmd (format #f "curl -s 'https://api.anthropic.com/v1/messages' -H 'Content-Type: application/json' -H 'x-api-key: ~a' -H 'anthropic-version: 2023-06-01' -d '~a'"
                      api-key (escape-for-shell payload)))
         (port (open-input-pipe cmd))
         (response (get-string-all port)))
    (close-pipe port)
    ;; Extract text from JSON response
    (let ((match (string-match "\"text\":\"([^\"]+)\"" response)))
      (if match
          (match:substring match 1)
          ""))))

;;; --------------------------------------------------------------------
;;; Prompts
;;; --------------------------------------------------------------------

(define (make-answer-prompt context question)
  (format #f "Based on this context, answer briefly.

Context: ~a

Question: ~a

Answer:"
          (if (> (string-length context) 4000)
              (substring context 0 4000)
              context)
          question))

(define (make-judge-prompt question gold generated)
  (format #f "Is this answer correct?

Question: ~a
Expected: ~a
Got: ~a

Reply CORRECT or WRONG only."
          question gold generated))

;;; --------------------------------------------------------------------
;;; Main Evaluation
;;; --------------------------------------------------------------------

(define category-names
  '((1 . "single_hop") (2 . "temporal") (3 . "commonsense")
    (4 . "multi_hop") (5 . "adversarial")))

(define (run-benchmark condition-name limit)
  "Run the LoCoMo benchmark for a condition."

  (format #t "~%")
  (format #t "╔══════════════════════════════════════════════════════════════╗~%")
  (format #t "║         LoCoMo Benchmark: ~a                     ║~%" condition-name)
  (format #t "╚══════════════════════════════════════════════════════════════╝~%~%")

  ;; Check API key
  (unless (getenv "ANTHROPIC_API_KEY")
    (format #t "Error: ANTHROPIC_API_KEY not set~%")
    (format #t "Run: export ANTHROPIC_API_KEY=your_key~%")
    (exit 1))

  ;; Load dataset
  (format #t "Loading dataset...~%")
  (let* ((json-str (call-with-input-file "eval/locomo/data/locomo10.json" get-string-all))
         (conversations (json-string->scm json-str))
         (conv (car conversations))
         (conv-id (assoc-ref conv "sample_id")))

    ;; Ingest
    (format #t "Ingesting ~a into xm graph...~%" conv-id)
    (let ((store (make-memory-store)))
      (ingest-conversation store conv)

      ;; Create retriever
      (format #t "Creating ~a retriever...~%~%" condition-name)
      (let ((retriever (make-retriever (string->symbol condition-name) #:max-tokens 4000)))

        ;; Filter and limit QA pairs (skip adversarial category 5)
        (let* ((all-qa (assoc-ref conv "qa"))
               (filtered (filter (lambda (qa) (not (= (assoc-ref qa "category") 5))) all-qa))
               (test-qa (take filtered (min limit (length filtered)))))

          (format #t "Evaluating ~a questions...~%~%" (length test-qa))

          ;; Run evaluation
          (let ((results
                 (let loop ((qas test-qa) (idx 1) (acc '()))
                   (if (null? qas)
                       (reverse acc)
                       (let* ((qa (car qas))
                              (question (assoc-ref qa "question"))
                              (gold-raw (assoc-ref qa "answer"))
                              (gold (if (string? gold-raw) gold-raw (format #f "~a" gold-raw)))
                              (category (assoc-ref qa "category")))

                         (format #t "[~a/~a] ~a~%"
                                 idx (length test-qa)
                                 (if (> (string-length question) 55)
                                     (string-append (substring question 0 55) "...")
                                     question))

                         ;; Retrieve context
                         (let* ((ctx-result (retriever store conv-id question))
                                (context (or (assoc-ref ctx-result 'context) ""))
                                ;; Generate answer
                                (answer-prompt (make-answer-prompt context question))
                                (generated (call-claude-api answer-prompt 80))
                                ;; Judge
                                (judge-prompt (make-judge-prompt question gold generated))
                                (judgment (call-claude-api judge-prompt 10))
                                (score (if (string-contains-ci judgment "CORRECT") 1 0)))

                           (format #t "   Expected: ~a~%"
                                   (if (> (string-length gold) 45)
                                       (string-append (substring gold 0 45) "...")
                                       gold))
                           (format #t "   Got:      ~a~%"
                                   (if (> (string-length generated) 45)
                                       (string-append (substring generated 0 45) "...")
                                       generated))
                           (format #t "   ~a~%~%"
                                   (if (= score 1) "✓ CORRECT" "✗ WRONG"))

                           (loop (cdr qas) (+ idx 1)
                                 (cons (list category score) acc))))))))

            ;; Close store
            (store-close store)

            ;; Calculate and print metrics
            (print-results condition-name results)))))))

(define (print-results condition-name results)
  "Print evaluation results."
  (format #t "~%")
  (format #t "════════════════════════════════════════════════════════════════~%")
  (format #t "Results: ~a~%" condition-name)
  (format #t "════════════════════════════════════════════════════════════════~%~%")

  (format #t "~15a ~10a ~8a ~10a~%" "Category" "Correct" "Total" "Accuracy")
  (format #t "~a~%" (make-string 47 #\-))

  ;; By category
  (for-each
   (lambda (cat-num)
     (let* ((cat-results (filter (lambda (r) (= (car r) cat-num)) results))
            (total (length cat-results))
            (correct (apply + (map cadr cat-results)))
            (accuracy (if (> total 0) (* 100.0 (/ correct total)) 0)))
       (when (> total 0)
         (format #t "~15a ~10a ~8a ~9,1f%~%"
                 (assoc-ref category-names cat-num) correct total accuracy))))
   '(1 2 3 4))

  ;; Overall
  (format #t "~a~%" (make-string 47 #\-))
  (let* ((total (length results))
         (correct (apply + (map cadr results)))
         (accuracy (if (> total 0) (* 100.0 (/ correct total)) 0)))
    (format #t "~15a ~10a ~8a ~9,1f%~%~%" "OVERALL" correct total accuracy)))

(define (string-contains-ci haystack needle)
  "Case-insensitive string-contains."
  (string-contains (string-upcase haystack) (string-upcase needle)))

;;; --------------------------------------------------------------------
;;; Entry Point
;;; --------------------------------------------------------------------

(define (main args)
  (let* ((condition (if (> (length args) 1)
                        (list-ref args 1)
                        "xm-sparql"))
         (limit (if (> (length args) 2)
                    (string->number (list-ref args 2))
                    20)))
    (run-benchmark condition limit)))
