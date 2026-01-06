#!/usr/bin/env guile
!#
;;; eval/locomo/test-eval.scm --- Test script for LoCoMo evaluation
;;;
;;; Run with:
;;;   cd xm && guile -L guile -L eval/locomo test-eval.scm
;;;
;;; Or from xm directory:
;;;   guile -L guile -L eval/locomo eval/locomo/test-eval.scm

(add-to-load-path (string-append (getcwd) "/guile"))
(add-to-load-path (string-append (getcwd) "/eval/locomo"))

(use-modules (ice-9 format)
             (xm store)
             (xm vocabulary))

;; Try to load eval modules
(format #t "~%=== LoCoMo Evaluation Test ===~%~%")

(format #t "1. Testing module imports...~%")

(catch #t
  (lambda ()
    (use-modules (eval locomo ingest))
    (format #t "   ✓ ingest.scm loaded~%"))
  (lambda (key . args)
    (format #t "   ✗ ingest.scm failed: ~a ~a~%" key args)))

(catch #t
  (lambda ()
    (use-modules (eval locomo retrieve))
    (format #t "   ✓ retrieve.scm loaded~%"))
  (lambda (key . args)
    (format #t "   ✗ retrieve.scm failed: ~a ~a~%" key args)))

(catch #t
  (lambda ()
    (use-modules (eval locomo evaluate))
    (format #t "   ✓ evaluate.scm loaded~%"))
  (lambda (key . args)
    (format #t "   ✗ evaluate.scm failed: ~a ~a~%" key args)))

(catch #t
  (lambda ()
    (use-modules (eval locomo conditions))
    (format #t "   ✓ conditions.scm loaded~%"))
  (lambda (key . args)
    (format #t "   ✗ conditions.scm failed: ~a ~a~%" key args)))

(catch #t
  (lambda ()
    (use-modules (eval locomo runner))
    (format #t "   ✓ runner.scm loaded~%"))
  (lambda (key . args)
    (format #t "   ✗ runner.scm failed: ~a ~a~%" key args)))

(format #t "~%2. Testing basic functionality...~%")

;; Test F1 score calculation
(catch #t
  (lambda ()
    (let* ((f1 ((@@ (eval locomo evaluate) compute-token-f1)
                "the quick brown fox"
                "the quick brown dog")))
      (format #t "   ✓ F1 score calculation: ~,3f (expected ~0.75)~%" f1)))
  (lambda (key . args)
    (format #t "   ✗ F1 calculation failed: ~a~%" key)))

;; Test entity extraction
(catch #t
  (lambda ()
    (let ((entities ((@@ (eval locomo retrieve) extract-entities)
                     "When did Caroline attend the support group?")))
      (format #t "   ✓ Entity extraction: ~a~%" entities)))
  (lambda (key . args)
    (format #t "   ✗ Entity extraction failed: ~a~%" key)))

;; Test search term extraction
(catch #t
  (lambda ()
    (let ((terms ((@@ (eval locomo retrieve) extract-search-terms)
                  "What activities does Melanie partake in?")))
      (format #t "   ✓ Search terms: ~a~%" terms)))
  (lambda (key . args)
    (format #t "   ✗ Search term extraction failed: ~a~%" key)))

(format #t "~%3. Testing store and data...~%")

;; Check if dataset exists
(let ((data-path "eval/locomo/data/locomo10.json"))
  (if (file-exists? data-path)
      (format #t "   ✓ Dataset found: ~a~%" data-path)
      (format #t "   ✗ Dataset not found: ~a~%" data-path)))

;; Test memory store
(catch #t
  (lambda ()
    (let ((store (make-memory-store)))
      (format #t "   ✓ Memory store created~%")
      ;; Insert a test triple
      (store-insert-quad store
                         "http://example.org/test"
                         "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
                         "http://example.org/TestClass")
      (format #t "   ✓ Test quad inserted~%")
      ;; Query it back
      (let ((result (store-query store
                                  "SELECT ?s WHERE { ?s a <http://example.org/TestClass> }")))
        (format #t "   ✓ SPARQL query executed~%"))
      (store-close store)
      (format #t "   ✓ Store closed~%")))
  (lambda (key . args)
    (format #t "   ✗ Store test failed: ~a ~a~%" key args)))

(format #t "~%4. Quick ingestion test...~%")

(catch #t
  (lambda ()
    ;; Load a single conversation and test ingestion
    (let* ((data-path "eval/locomo/data/locomo10.json")
           (store (make-memory-store)))
      (if (file-exists? data-path)
          (let* ((json-str (call-with-input-file data-path
                             (lambda (port)
                               (let loop ((chars '()))
                                 (let ((c (read-char port)))
                                   (if (eof-object? c)
                                       (list->string (reverse chars))
                                       (loop (cons c chars))))))))
                 (conversations (json-string->scm json-str))
                 (first-conv (car conversations))
                 (conv-id (assoc-ref first-conv "sample_id")))
            (format #t "   Found ~a conversations~%" (length conversations))
            (format #t "   First conversation: ~a~%" conv-id)

            ;; Test ingestion
            (format #t "   Ingesting first conversation...~%")
            (let ((result ((@@ (eval locomo ingest) ingest-conversation)
                           store first-conv #:verbose #f)))
              (format #t "   ✓ Ingested: ~a~%" result))

            ;; Check what was created
            (let* ((count-query "SELECT (COUNT(*) AS ?count) WHERE { ?s ?p ?o }")
                   (result (store-query store count-query))
                   (parsed (json-string->scm result)))
              (format #t "   ✓ Total triples in store: ~a~%"
                      (assoc-ref (assoc-ref (car (assoc-ref (assoc-ref parsed "results") "bindings"))
                                            "count")
                                 "value")))

            (store-close store))
          (format #t "   ⚠ Skipping - dataset not found~%"))))
  (lambda (key . args)
    (format #t "   ✗ Ingestion test failed: ~a ~a~%" key args)))

(format #t "~%=== Test Complete ===~%~%")
