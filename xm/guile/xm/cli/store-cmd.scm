;;; xm/cli/store-cmd.scm --- Store management commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements store compact/backup/restore/info commands per SPEC-029 Section 5.21.
;;; Store commands provide maintenance and administration operations.

(define-module (xm cli store-cmd)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-store-command
            cmd-store-compact
            cmd-store-backup
            cmd-store-restore
            cmd-store-info))

;;; --------------------------------------------------------------------
;;; Store Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-store-command subcommand opts global-opts store cap-ref)
  "Dispatch store subcommands."
  (case subcommand
    ((compact) (cmd-store-compact opts global-opts store cap-ref))
    ((backup) (cmd-store-backup opts global-opts store cap-ref))
    ((restore) (cmd-store-restore opts global-opts store cap-ref))
    ((info) (cmd-store-info opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown store subcommand: ~a" subcommand)
                   "Available: compact, backup, restore, info"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; store compact
;;; --------------------------------------------------------------------

(define (cmd-store-compact opts global-opts store cap-ref)
  "Compact and optimize the store.
   Persists current data and reports statistics."

  ;; Persist current state
  (store-persist store)

  (let* ((triple-count (store-count store))
         (graphs (store-list-graphs store))
         (graph-count (length graphs)))

    (if (assoc-ref global-opts "json")
        (output-result `((ok . #t)
                         (data . ((compacted . #t)
                                  (triple_count . ,triple-count)
                                  (graph_count . ,graph-count))))
                       global-opts)
        (begin
          (format #t "Store compacted.\n")
          (format #t "  Triples: ~a\n" triple-count)
          (format #t "  Graphs:  ~a\n" graph-count)))))

;;; --------------------------------------------------------------------
;;; store backup
;;; --------------------------------------------------------------------

(define (cmd-store-backup opts global-opts store cap-ref)
  "Backup the store to a file.
   Usage: xm store backup -o <file>

   Options:
   -o, --output FILE: Output file (required)
   -f, --format FORMAT: Output format (nquads, turtle, ntriples; default: nquads)"

  (let* ((output-file (or (assoc-ref opts "output")
                          (assoc-ref opts "o")))
         (format-opt (or (assoc-ref opts "format")
                         (assoc-ref opts "f")
                         "nquads")))

    (unless output-file
      (output-error "MISSING_OUTPUT"
                    "Output file is required"
                    "Usage: xm store backup -o <file>"
                    global-opts)
      (exit 2))

    ;; Validate format
    (unless (member format-opt '("nquads" "turtle" "ntriples"))
      (output-error "INVALID_FORMAT"
                    (format #f "Invalid format: ~a" format-opt)
                    "Supported formats: nquads, turtle, ntriples"
                    global-opts)
      (exit 2))

    ;; Dump all data
    (let* ((data (if (string=? format-opt "nquads")
                     (store-dump-all-nquads store)
                     (store-dump-graph store #:format format-opt)))
           (triple-count (store-count store))
           (timestamp (current-iso-timestamp)))

      ;; Write to file with header comment
      (call-with-output-file output-file
        (lambda (port)
          (format port "# xm backup\n")
          (format port "# created: ~a\n" timestamp)
          (format port "# triples: ~a\n" triple-count)
          (format port "# format: ~a\n\n" format-opt)
          (display data port)))

      (if (assoc-ref global-opts "json")
          (output-result `((ok . #t)
                           (data . ((backed_up_to . ,output-file)
                                    (triple_count . ,triple-count)
                                    (format . ,format-opt)
                                    (timestamp . ,timestamp))))
                         global-opts)
          (format #t "Backed up ~a triples to ~a\n" triple-count output-file)))))

;;; --------------------------------------------------------------------
;;; store restore
;;; --------------------------------------------------------------------

(define (cmd-store-restore opts global-opts store cap-ref)
  "Restore the store from a backup file.
   Usage: xm store restore --from <file>

   Options:
   --from FILE: Backup file to restore from (required)
   --merge: Merge with existing data (default: replace)
   -f, --force: Skip confirmation prompt"

  (let* ((from-file (assoc-ref opts "from"))
         (merge (assoc-ref opts "merge"))
         (force (or (assoc-ref opts "force")
                    (assoc-ref opts "f"))))

    (unless from-file
      (output-error "MISSING_FROM"
                    "Backup file is required"
                    "Usage: xm store restore --from <file>"
                    global-opts)
      (exit 2))

    (unless (file-exists? from-file)
      (output-error "FILE_NOT_FOUND"
                    (format #f "Backup file not found: ~a" from-file)
                    "Check the file path"
                    global-opts)
      (exit 1))

    ;; Count existing triples
    (let ((existing-count (store-count store)))

      ;; Confirmation unless --force or --merge
      (unless (or force merge (assoc-ref global-opts "json"))
        (format #t "This will REPLACE ~a existing triples. Continue? [y/N] "
                existing-count)
        (let ((response (read-line)))
          (unless (and response
                       (member (string-downcase response) '("y" "yes")))
            (format #t "Cancelled.\n")
            (exit 0))))

      ;; Clear existing data unless merging
      (unless merge
        (let ((graphs (store-list-graphs store)))
          (for-each (lambda (g) (store-drop-graph store g)) graphs)))

      ;; Read and load backup data
      (let* ((data (call-with-input-file from-file
                     (lambda (port)
                       (get-string-all port))))
             ;; Detect format from file content or extension
             (format-type (detect-backup-format from-file data)))

        (store-load-graph store data #:format format-type)

        (let ((new-count (store-count store)))
          (if (assoc-ref global-opts "json")
              (output-result `((ok . #t)
                               (data . ((restored_from . ,from-file)
                                        (triple_count . ,new-count)
                                        (merged . ,(if merge #t #f)))))
                             global-opts)
              (begin
                (if merge
                    (format #t "Merged ~a triples from ~a (total: ~a)\n"
                            (- new-count existing-count) from-file new-count)
                    (format #t "Restored ~a triples from ~a\n"
                            new-count from-file)))))))))

;;; --------------------------------------------------------------------
;;; store info
;;; --------------------------------------------------------------------

(define (cmd-store-info opts global-opts store cap-ref)
  "Show store information and statistics."

  (let* ((total-count (store-count store))
         (is-empty (store-empty? store))
         (graphs (store-list-graphs store))
         (graph-stats (map (lambda (uri)
                             `((uri . ,(compact-uri uri))
                               (triple_count . ,(store-graph-count store uri))))
                           graphs))
         ;; Get top classes via SPARQL
         (top-classes (get-top-classes-all store 10))
         ;; Get top predicates via SPARQL
         (top-predicates (get-top-predicates-all store 10))
         ;; Build info
         (info `((total_triples . ,total-count)
                 (empty . ,is-empty)
                 (graph_count . ,(length graphs))
                 (graphs . ,graph-stats)
                 (top_classes . ,top-classes)
                 (top_predicates . ,top-predicates))))

    (if (assoc-ref global-opts "json")
        (output-result `((ok . #t)
                         (data . ,info))
                       global-opts)
        ;; Human-readable output
        (display-store-info-human info))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time in ISO8601 format."
  (let ((now (current-time)))
    (format #f "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            (+ 1900 (tm:year (localtime now)))
            (+ 1 (tm:mon (localtime now)))
            (tm:mday (localtime now))
            (tm:hour (localtime now))
            (tm:min (localtime now))
            (tm:sec (localtime now)))))

(define (detect-backup-format file-path data)
  "Detect backup format from file extension or content."
  (cond
   ((string-suffix? ".nq" file-path) "nquads")
   ((string-suffix? ".ttl" file-path) "turtle")
   ((string-suffix? ".nt" file-path) "ntriples")
   ;; Check content for N-Quads (4 fields per line)
   ((string-contains data " <") "nquads")
   (else "nquads")))

(define (get-top-classes-all store limit)
  "Get top N classes by instance count across all graphs."
  (let* ((sparql (format #f "SELECT ?type (COUNT(?s) AS ?count)
WHERE { ?s a ?type }
GROUP BY ?type
ORDER BY DESC(?count)
LIMIT ~a" limit))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (binding)
           (let ((type-val (get-binding-value binding "type"))
                 (count-val (get-binding-value binding "count")))
             `((uri . ,(if type-val (compact-uri type-val) "unknown"))
               (count . ,(if count-val (string->number count-val) 0)))))
         bindings)))

(define (get-top-predicates-all store limit)
  "Get top N predicates by usage count across all graphs."
  (let* ((sparql (format #f "SELECT ?p (COUNT(*) AS ?count)
WHERE { ?s ?p ?o }
GROUP BY ?p
ORDER BY DESC(?count)
LIMIT ~a" limit))
         (json-result (store-query store sparql))
         (parsed (json-string->scm json-result))
         (bindings (get-sparql-bindings parsed)))
    (map (lambda (binding)
           (let ((pred-val (get-binding-value binding "p"))
                 (count-val (get-binding-value binding "count")))
             `((uri . ,(if pred-val (compact-uri pred-val) "unknown"))
               (count . ,(if count-val (string->number count-val) 0)))))
         bindings)))

(define (display-store-info-human info)
  "Display store info in human-readable format."
  (format #t "\n=== Store Information ===\n\n")
  (format #t "Total Triples: ~a\n" (assoc-ref info 'total_triples))
  (format #t "Empty: ~a\n" (if (assoc-ref info 'empty) "yes" "no"))
  (format #t "Graph Count: ~a\n" (assoc-ref info 'graph_count))

  (let ((graphs (assoc-ref info 'graphs)))
    (when (and graphs (not (null? graphs)))
      (format #t "\nNamed Graphs:\n")
      (for-each
       (lambda (g)
         (format #t "  ~40a ~6d triples\n"
                 (assoc-ref g 'uri)
                 (assoc-ref g 'triple_count)))
       graphs)))

  (let ((classes (assoc-ref info 'top_classes)))
    (when (and classes (not (null? classes)))
      (format #t "\nTop Classes:\n")
      (for-each
       (lambda (cls)
         (format #t "  ~30a ~6d\n"
                 (assoc-ref cls 'uri)
                 (assoc-ref cls 'count)))
       classes)))

  (let ((predicates (assoc-ref info 'top_predicates)))
    (when (and predicates (not (null? predicates)))
      (format #t "\nTop Predicates:\n")
      (for-each
       (lambda (pred)
         (format #t "  ~30a ~6d\n"
                 (assoc-ref pred 'uri)
                 (assoc-ref pred 'count)))
       predicates)))

  (newline))

;;; --------------------------------------------------------------------
;;; SPARQL Result Parsing Helpers
;;; --------------------------------------------------------------------

(define (get-sparql-bindings parsed)
  "Extract bindings list from parsed SPARQL JSON result."
  (let ((results (assoc-ref parsed "results")))
    (if results
        (or (assoc-ref results "bindings") '())
        '())))

(define (get-binding-value binding var-name)
  "Get the value of a variable from a SPARQL binding."
  (let ((var-data (assoc-ref binding var-name)))
    (if var-data
        (assoc-ref var-data "value")
        #f)))

;;; --------------------------------------------------------------------
;;; File I/O Helpers
;;; --------------------------------------------------------------------

(define (read-line)
  "Read a line from standard input."
  (let loop ((chars '()))
    (let ((c (read-char)))
      (cond
       ((eof-object? c)
        (if (null? chars) #f (list->string (reverse chars))))
       ((char=? c #\newline)
        (list->string (reverse chars)))
       (else
        (loop (cons c chars)))))))

(define (get-string-all port)
  "Read all remaining characters from PORT as a string."
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define (file-exists? path)
  "Check if a file exists."
  (catch 'system-error
    (lambda () (stat path) #t)
    (lambda args #f)))

(define (string-suffix? suffix str)
  "Check if STR ends with SUFFIX."
  (let ((sl (string-length suffix))
        (strl (string-length str)))
    (and (>= strl sl)
         (string=? suffix (substring str (- strl sl))))))

(define (string-contains haystack needle)
  "Check if HAYSTACK contains NEEDLE."
  (let loop ((i 0))
    (cond
     ((> (+ i (string-length needle)) (string-length haystack)) #f)
     ((string=? needle (substring haystack i (+ i (string-length needle)))) #t)
     (else (loop (+ i 1))))))

(define (string-downcase str)
  "Convert string to lowercase."
  (list->string (map char-downcase (string->list str))))

(define (store-dump-all-nquads store)
  "Dump all quads to N-Quads format."
  ;; Use SPARQL CONSTRUCT to get all triples
  (let* ((sparql "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
         (result (store-dump-graph store #:format "nquads")))
    result))
