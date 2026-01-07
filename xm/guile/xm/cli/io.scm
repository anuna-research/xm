;;; xm/cli/io.scm --- Import/Export commands for CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; Implements import/export commands per SPEC-029 Section 5.18.
;;; Provides data portability through RDF serialization formats.

(define-module (xm cli io)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-import-command
            handle-export-command))

;;; --------------------------------------------------------------------
;;; import command
;;; --------------------------------------------------------------------

(define (handle-import-command opts global-opts store cap-ref)
  "Import RDF data from a file into the store.
   Usage: xm import <file> [options]

   Options:
   -g, --graph URI: Target graph (default: xm:graph/public)
   -f, --format FORMAT: Input format (turtle, ntriples, nquads; auto-detect from extension)
   --replace: Replace graph contents instead of merging"

  (let* ((positional (assoc-ref opts 'positional))
         (file-path (and (pair? positional) (car positional)))
         (graph-opt (or (assoc-ref opts "graph")
                        (assoc-ref opts "g")))
         (format-opt (or (assoc-ref opts "format")
                         (assoc-ref opts "f")))
         (replace (assoc-ref opts "replace")))

    (unless file-path
      (output-error "MISSING_FILE"
                    "Input file is required"
                    "Usage: xm import <file> [-g graph] [-f format]"
                    global-opts)
      (exit 2))

    (unless (file-exists? file-path)
      (output-error "FILE_NOT_FOUND"
                    (format #f "File not found: ~a" file-path)
                    "Check the file path"
                    global-opts)
      (exit 1))

    (let* ((graph-uri (if graph-opt
                          (expand-uri graph-opt)
                          (public-graph-uri)))
           (format-type (or format-opt (detect-format file-path)))
           (data (read-file-contents file-path)))

      ;; Validate format
      (unless (member format-type '("turtle" "ntriples" "nquads"))
        (output-error "INVALID_FORMAT"
                      (format #f "Unknown format: ~a" format-type)
                      "Supported formats: turtle, ntriples, nquads"
                      global-opts)
        (exit 2))

      ;; Count existing triples in target graph
      (let ((existing-count (if (store-graph-exists? store graph-uri)
                                (store-graph-count store graph-uri)
                                0)))

        ;; Clear graph if --replace specified
        (when (and replace (> existing-count 0))
          (store-clear-graph store graph-uri))

        ;; Load the data
        (store-load-graph store data #:graph graph-uri #:format format-type)

        ;; Count new triples
        (let ((new-count (store-graph-count store graph-uri)))

          (if (assoc-ref global-opts "json")
              (output-result `((imported_from . ,file-path)
                               (graph . ,(compact-uri graph-uri))
                               (format . ,format-type)
                               (triples_added . ,(- new-count
                                                     (if replace 0 existing-count)))
                               (total_triples . ,new-count)
                               (replaced . ,(if replace #t #f)))
                             global-opts)
              (begin
                (format #t "Imported from ~a\n" file-path)
                (format #t "  Graph: ~a\n" (compact-uri graph-uri))
                (format #t "  Format: ~a\n" format-type)
                (format #t "  Triples: ~a (was: ~a)\n"
                        new-count (if replace 0 existing-count)))))))))

;;; --------------------------------------------------------------------
;;; export command
;;; --------------------------------------------------------------------

(define (handle-export-command opts global-opts store cap-ref)
  "Export RDF data from the store to a file or stdout.
   Usage: xm export [options]

   Options:
   -g, --graph URI: Source graph (default: all graphs)
   -o, --output FILE: Output file (default: stdout)
   -f, --format FORMAT: Output format (turtle, ntriples, nquads; default: turtle)"

  (let* ((graph-opt (or (assoc-ref opts "graph")
                        (assoc-ref opts "g")))
         (output-file (or (assoc-ref opts "output")
                          (assoc-ref opts "o")))
         (format-opt (or (assoc-ref opts "format")
                         (assoc-ref opts "f")
                         "turtle")))

    ;; Validate format
    (unless (member format-opt '("turtle" "ntriples" "nquads"))
      (output-error "INVALID_FORMAT"
                    (format #f "Unknown format: ~a" format-opt)
                    "Supported formats: turtle, ntriples, nquads"
                    global-opts)
      (exit 2))

    (let* ((graph-uri (and graph-opt (expand-uri graph-opt)))
           (data (if graph-uri
                     ;; Export single graph
                     (begin
                       (unless (store-graph-exists? store graph-uri)
                         (output-error "GRAPH_NOT_FOUND"
                                       (format #f "Graph not found: ~a" (compact-uri graph-uri))
                                       "Use 'xm graph list' to see available graphs"
                                       global-opts)
                         (exit 1))
                       (store-dump-graph store #:graph graph-uri #:format format-opt))
                     ;; Export all graphs (N-Quads preserves graph info)
                     (if (string=? format-opt "nquads")
                         (store-dump-all-nquads store)
                         (store-dump-graph store #:format format-opt))))
           (triple-count (if graph-uri
                             (store-graph-count store graph-uri)
                             (store-count store))))

      ;; Output to file or stdout
      (if output-file
          (begin
            (call-with-output-file output-file
              (lambda (port)
                (display data port)))
            (if (assoc-ref global-opts "json")
                (output-result `((exported_to . ,output-file)
                                 (graph . ,(if graph-uri
                                               (compact-uri graph-uri)
                                               "all"))
                                 (format . ,format-opt)
                                 (triple_count . ,triple-count))
                               global-opts)
                (format #t "Exported ~a triples to ~a\n" triple-count output-file)))
          ;; Output to stdout
          (if (assoc-ref global-opts "json")
              ;; In JSON mode, include the RDF data
              (output-result `((graph . ,(if graph-uri
                                             (compact-uri graph-uri)
                                             "all"))
                               (format . ,format-opt)
                               (triple_count . ,triple-count)
                               (content . ,data))
                             global-opts)
              ;; Human mode: just output the RDF data
              (display data))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (detect-format file-path)
  "Detect RDF format from file extension."
  (cond
   ((string-suffix? ".ttl" file-path) "turtle")
   ((string-suffix? ".nt" file-path) "ntriples")
   ((string-suffix? ".nq" file-path) "nquads")
   ((string-suffix? ".n3" file-path) "turtle")
   ((string-suffix? ".rdf" file-path) "turtle")  ; RDF/XML not supported, try turtle
   (else "turtle")))  ; Default to turtle

(define (read-file-contents file-path)
  "Read entire file contents as a string."
  (call-with-input-file file-path
    (lambda (port)
      (get-string-all port))))

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

(define (public-graph-uri)
  "Get the default public graph URI."
  (xm-graph-uri "public"))

(define (store-dump-all-nquads store)
  "Dump all quads to N-Quads format."
  (store-dump-graph store #:format "nquads"))
