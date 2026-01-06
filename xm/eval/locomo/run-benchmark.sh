#!/bin/bash
# LoCoMo Benchmark Runner for xm
# Usage: ./eval/locomo/run-benchmark.sh [condition] [limit]

CONDITION=${1:-xm-sparql}
LIMIT=${2:-20}

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "Error: ANTHROPIC_API_KEY not set"
    echo "Run: export ANTHROPIC_API_KEY=your_key"
    exit 1
fi

echo ""
echo "========================================================================"
echo "  LoCoMo Benchmark: $CONDITION (limit=$LIMIT)"
echo "========================================================================"
echo ""

guile -L guile -L eval/locomo -c "
(use-modules (ice-9 format)
             (ice-9 popen)
             (ice-9 rdelim)
             (srfi srfi-1)
             (xm store)
             (eval locomo ingest)
             (eval locomo retrieve)
             (eval locomo conditions))

;;; Helpers
(define (get-string-all port)
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define (escape-json str)
  (let ((result '()))
    (string-for-each
     (lambda (c)
       (set! result
             (cons (case c
                     ((#\\\") \"\\\\\\\"\")
                     ((#\\\\) \"\\\\\\\\\")
                     ((#\\newline) \"\\\\n\")
                     ((#\\tab) \"\\\\t\")
                     ((#\\return) \"\")
                     (else (string c)))
                   result)))
     str)
    (apply string-append (reverse result))))

(define (call-claude prompt max-tokens)
  (let* ((api-key (getenv \"ANTHROPIC_API_KEY\"))
         (escaped (escape-json prompt))
         (cmd (format #f \"curl -s 'https://api.anthropic.com/v1/messages' -H 'Content-Type: application/json' -H 'x-api-key: ~a' -H 'anthropic-version: 2023-06-01' -d '{\\\"model\\\": \\\"claude-3-haiku-20240307\\\", \\\"max_tokens\\\": ~a, \\\"messages\\\": [{\\\"role\\\": \\\"user\\\", \\\"content\\\": \\\"~a\\\"}]}'\" api-key max-tokens escaped))
         (port (open-input-pipe cmd))
         (response (get-string-all port)))
    (close-pipe port)
    ;; Extract text from response
    (let ((start (string-contains response \"\\\"text\\\":\\\"\")))
      (if start
          (let* ((text-start (+ start 8))
                 (rest (substring response text-start))
                 (end (string-index rest #\\\")))
            (if end (substring rest 0 end) \"\"))
          \"\"))))

(define answer-prompt \"Based on the following conversation context, answer the question concisely.
If the answer cannot be determined from the context, say 'Cannot determine'.

Context:
~a

Question: ~a

Answer (be brief and direct):\")

(define judge-prompt \"You are evaluating a QA system.
Question: ~a
Gold Answer: ~a
Generated Answer: ~a

Is the generated answer correct? Be generous - if it conveys the same meaning, it's correct.
Respond with ONLY: CORRECT or WRONG\")

(define category-names
  '((1 . \"single_hop\") (2 . \"temporal\") (3 . \"commonsense\") (4 . \"multi_hop\") (5 . \"adversarial\")))

;;; Main evaluation
(define condition (quote $CONDITION))
(define limit $LIMIT)

(format #t \"Loading dataset...~%\")
(define json-str (call-with-input-file \"eval/locomo/data/locomo10.json\" get-string-all))
(define conversations (json-string->scm json-str))
(define conv (car conversations))
(define conv-id (assoc-ref conv \"sample_id\"))

(format #t \"Ingesting conversation ~a...~%\" conv-id)
(define store (make-memory-store))
(ingest-conversation store conv)

(format #t \"Creating retriever for ~a...~%~%\" condition)
(define retriever (make-retriever condition #:max-tokens 4000))

;; Filter QA pairs (skip category 5)
(define all-qa (assoc-ref conv \"qa\"))
(define test-qa (take (filter (lambda (qa) (not (= (assoc-ref qa \"category\") 5))) all-qa)
                      (min limit (length all-qa))))

(format #t \"Evaluating ~a questions...~%~%\" (length test-qa))

;; Run evaluation
(define results
  (let loop ((qas test-qa) (idx 1) (results '()))
    (if (null? qas)
        (reverse results)
        (let* ((qa (car qas))
               (question (assoc-ref qa \"question\"))
               (gold (let ((a (assoc-ref qa \"answer\"))) (if (string? a) a (format #f \"~a\" a))))
               (category (assoc-ref qa \"category\")))

          (format #t \"[~a/~a] ~a~%\" idx (length test-qa)
                  (if (> (string-length question) 55)
                      (string-append (substring question 0 55) \"...\")
                      question))

          ;; Retrieve context
          (let* ((ctx-result (retriever store conv-id question))
                 (context (assoc-ref ctx-result 'context))
                 (ctx-truncated (if (> (string-length context) 5000)
                                    (substring context 0 5000)
                                    context)))

            ;; Generate answer
            (let* ((gen-prompt (format #f answer-prompt ctx-truncated question))
                   (generated (call-claude gen-prompt 100)))

              ;; Judge answer
              (let* ((j-prompt (format #f judge-prompt question gold generated))
                     (judgment (call-claude j-prompt 10))
                     (score (if (string-contains (string-upcase judgment) \"CORRECT\") 1 0)))

                (format #t \"   Gold: ~a~%\" (if (> (string-length gold) 50)
                                              (string-append (substring gold 0 50) \"...\") gold))
                (format #t \"   Got:  ~a~%\" (if (> (string-length generated) 50)
                                              (string-append (substring generated 0 50) \"...\") generated))
                (format #t \"   ~a~%~%\" (if (= score 1) \"✓ CORRECT\" \"✗ WRONG\"))

                (loop (cdr qas) (+ idx 1)
                      (cons (list category score (string-length context)) results)))))))))

(store-close store)

;; Calculate metrics
(format #t \"~%========================================~%\")
(format #t \"Results: ~a~%\" condition)
(format #t \"========================================~%~%\")

(format #t \"~15a ~10a ~8a ~10a~%\" \"Category\" \"Correct\" \"Total\" \"Accuracy\")
(format #t \"~a~%\" (make-string 45 #\\-))

(for-each
 (lambda (cat-num)
   (let* ((cat-results (filter (lambda (r) (= (car r) cat-num)) results))
          (cat-scores (map cadr cat-results))
          (total (length cat-scores))
          (correct (apply + cat-scores))
          (accuracy (if (> total 0) (* 100.0 (/ correct total)) 0)))
     (when (> total 0)
       (format #t \"~15a ~10a ~8a ~9,1f%~%\"
               (assoc-ref category-names cat-num) correct total accuracy))))
 '(1 2 3 4))

(format #t \"~a~%\" (make-string 45 #\\-))
(let* ((all-scores (map cadr results))
       (total (length all-scores))
       (correct (apply + all-scores))
       (accuracy (if (> total 0) (* 100.0 (/ correct total)) 0)))
  (format #t \"~15a ~10a ~8a ~9,1f%~%\" \"OVERALL\" correct total accuracy))

(format #t \"~%\")
"
