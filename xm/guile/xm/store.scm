;;; xm/store.scm --- FFI bindings to Oxigraph via libxm_ffi
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module provides Guile bindings to the Oxigraph RDF store
;;; via the xm_ffi Rust library.

(define-module (xm store)
  #:use-module (system foreign)
  #:use-module (system foreign-library)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:export (;; Store lifecycle
            make-store
            make-memory-store
            store?
            store-close
            store-persist
            with-store

            ;; SPARQL operations
            store-query
            store-update

            ;; Quad operations
            store-insert-quad
            store-delete-quad

            ;; Serialization
            store-dump-graph
            store-load-graph

            ;; Statistics
            store-count
            store-empty?

            ;; Named graph operations
            store-list-graphs
            store-graph-exists?
            store-create-graph
            store-drop-graph
            store-clear-graph
            store-graph-count

            ;; UUID generation
            generate-uuid

            ;; JSON parsing
            json-string->scm

            ;; Error handling
            xm-error?
            xm-error-code
            xm-error-message))

;;; --------------------------------------------------------------------
;;; FFI Library Loading
;;; --------------------------------------------------------------------

;; Try to load the library from various locations
(define libxm-ffi
  (or
   ;; Try development path first (from XM_LIB_PATH env var)
   (let ((lib-path (getenv "XM_LIB_PATH")))
     (and lib-path
          (false-if-exception
           (load-foreign-library
            (string-append lib-path "/libxm_ffi")))))
   ;; Try DYLD_LIBRARY_PATH (macOS)
   (false-if-exception
    (load-foreign-library "libxm_ffi"))
   ;; Try relative to common xm locations
   (false-if-exception
    (load-foreign-library
     (string-append (getenv "HOME") "/Code/meld/xm/target/release/libxm_ffi")))
   (error "Cannot load libxm_ffi shared library. Set XM_LIB_PATH environment variable.")))

;;; --------------------------------------------------------------------
;;; Error Codes (matching Rust XmError enum)
;;; --------------------------------------------------------------------

(define XM-ERROR-OK 0)
(define XM-ERROR-NULL-POINTER -1)
(define XM-ERROR-INVALID-UTF8 -2)
(define XM-ERROR-STORE-ERROR -3)
(define XM-ERROR-QUERY-ERROR -4)
(define XM-ERROR-SERIALIZATION-ERROR -5)
(define XM-ERROR-BUFFER-TOO-SMALL -6)
(define XM-ERROR-INVALID-FORMAT -7)

(define-record-type <xm-error>
  (make-xm-error code message)
  xm-error?
  (code xm-error-code)
  (message xm-error-message))

(define (error-code->message code)
  (case code
    ((-1) "Null pointer")
    ((-2) "Invalid UTF-8")
    ((-3) "Store error")
    ((-4) "Query error")
    ((-5) "Serialization error")
    ((-6) "Buffer too small")
    ((-7) "Invalid format")
    (else (format #f "Unknown error ~a" code))))

(define (check-result result)
  "Check if result is an error code and raise an exception if so."
  (if (< result 0)
      (raise-exception
       (make-xm-error result (error-code->message result)))
      result))

;;; --------------------------------------------------------------------
;;; FFI Function Bindings
;;; --------------------------------------------------------------------

;; Store lifecycle
(define ffi-store-open
  (foreign-library-function libxm-ffi "xm_store_open"
                            #:return-type '*
                            #:arg-types (list '*)))

(define ffi-store-open-memory
  (foreign-library-function libxm-ffi "xm_store_open_memory"
                            #:return-type '*
                            #:arg-types '()))

(define ffi-store-close
  (foreign-library-function libxm-ffi "xm_store_close"
                            #:return-type void
                            #:arg-types (list '*)))

;; SPARQL operations
(define ffi-store-query
  (foreign-library-function libxm-ffi "xm_store_query"
                            #:return-type int
                            #:arg-types (list '* '* '* size_t)))

(define ffi-store-update
  (foreign-library-function libxm-ffi "xm_store_update"
                            #:return-type int
                            #:arg-types (list '* '*)))

;; Quad operations
(define ffi-store-insert-quad
  (foreign-library-function libxm-ffi "xm_store_insert_quad"
                            #:return-type int
                            #:arg-types (list '* '* '* '* '*)))

(define ffi-store-delete-quad
  (foreign-library-function libxm-ffi "xm_store_delete_quad"
                            #:return-type int
                            #:arg-types (list '* '* '* '* '*)))

;; Serialization
(define ffi-store-dump-graph
  (foreign-library-function libxm-ffi "xm_store_dump_graph"
                            #:return-type int
                            #:arg-types (list '* '* '* '* size_t)))

(define ffi-store-dump-all
  (foreign-library-function libxm-ffi "xm_store_dump_all"
                            #:return-type int
                            #:arg-types (list '* '* size_t)))

(define ffi-store-load-graph
  (foreign-library-function libxm-ffi "xm_store_load_graph"
                            #:return-type int
                            #:arg-types (list '* '* '* '*)))

;; Statistics
(define ffi-store-count
  (foreign-library-function libxm-ffi "xm_store_count"
                            #:return-type int
                            #:arg-types (list '*)))

(define ffi-store-is-empty
  (foreign-library-function libxm-ffi "xm_store_is_empty"
                            #:return-type int
                            #:arg-types (list '*)))

;; Named graph operations
(define ffi-store-list-graphs
  (foreign-library-function libxm-ffi "xm_store_list_graphs"
                            #:return-type int
                            #:arg-types (list '* '* size_t)))

(define ffi-store-graph-exists
  (foreign-library-function libxm-ffi "xm_store_graph_exists"
                            #:return-type int
                            #:arg-types (list '* '*)))

(define ffi-store-create-graph
  (foreign-library-function libxm-ffi "xm_store_create_graph"
                            #:return-type int
                            #:arg-types (list '* '*)))

(define ffi-store-drop-graph
  (foreign-library-function libxm-ffi "xm_store_drop_graph"
                            #:return-type int
                            #:arg-types (list '* '*)))

(define ffi-store-clear-graph
  (foreign-library-function libxm-ffi "xm_store_clear_graph"
                            #:return-type int
                            #:arg-types (list '* '*)))

(define ffi-store-graph-count
  (foreign-library-function libxm-ffi "xm_store_graph_count"
                            #:return-type int
                            #:arg-types (list '* '*)))

;;; --------------------------------------------------------------------
;;; Store Type
;;; --------------------------------------------------------------------

(define-record-type <store>
  (%make-store ptr path data-file)
  store?
  (ptr store-ptr)
  (path store-path)
  (data-file store-data-file))

(define (make-store path)
  "Open or create an Oxigraph store at PATH.
   Due to RocksDB issues on macOS ARM64, this uses an in-memory store
   with file-based persistence (N-Quads format)."
  ;; Use in-memory store with file-based persistence as workaround
  (let* ((store-ptr (ffi-store-open-memory))
         (data-file (string-append path "/xm-data.nq")))
    (if (null-pointer? store-ptr)
        (raise-exception
         (make-xm-error XM-ERROR-STORE-ERROR
                        (format #f "Failed to create store for ~a" path)))
        (let ((store (%make-store store-ptr path data-file)))
          ;; Create directory if needed
          (ensure-directory-exists path)
          ;; Load existing data if present
          (store-load-from-file store)
          store))))

(define (make-memory-store)
  "Create an in-memory Oxigraph store (for testing)."
  (let ((store-ptr (ffi-store-open-memory)))
    (if (null-pointer? store-ptr)
        (raise-exception
         (make-xm-error XM-ERROR-STORE-ERROR "Failed to create memory store"))
        (%make-store store-ptr #f #f))))

(define (store-close store)
  "Close and free an Oxigraph store.
   Persists data to file before closing."
  (when (store-data-file store)
    (store-persist store))
  (ffi-store-close (store-ptr store)))

(define (store-persist store)
  "Persist store data to file (N-Quads format)."
  (when (store-data-file store)
    (let ((data (store-dump-all-nquads store)))
      (when (> (string-length data) 0)
        (call-with-output-file (store-data-file store)
          (lambda (port)
            (display data port)))))))

(define (store-load-from-file store)
  "Load data from persistence file if it exists."
  (let ((data-file (store-data-file store)))
    (when (and data-file (file-exists? data-file))
      (let ((data (call-with-input-file data-file
                    (lambda (port)
                      (get-string-all port)))))
        (when (> (string-length data) 0)
          (store-load-nquads store data))))))

(define (store-dump-all-nquads store)
  "Dump all quads (including named graphs) to N-Quads format."
  (let* ((buffer-size (* 10 1024 1024))  ; 10MB buffer
         (buffer (make-bytevector buffer-size 0))
         (buffer-ptr (bytevector->pointer buffer))
         (result (ffi-store-dump-all (store-ptr store)
                                      buffer-ptr buffer-size)))
    (if (>= result 0)
        (pointer->string buffer-ptr)
        "")))

(define (store-load-nquads store data)
  "Load N-Quads data into store."
  (let* ((fmt-ptr (string->pointer "nquads"))
         (data-ptr (string->pointer data))
         (result (ffi-store-load-graph (store-ptr store)
                                        %null-pointer
                                        fmt-ptr data-ptr)))
    (when (< result 0)
      (format (current-error-port)
              "Warning: Failed to load data from persistence file~%"))))

(define (ensure-directory-exists path)
  "Create directory PATH if it doesn't exist."
  (unless (file-exists? path)
    (mkdir path)))

(define (get-string-all port)
  "Read all remaining characters from PORT as a string."
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define-syntax with-store
  (syntax-rules ()
    "Execute BODY with STORE bound, ensuring store is closed on exit."
    ((_ (store path) body ...)
     (let ((store (make-store path)))
       (dynamic-wind
         (lambda () #t)
         (lambda () body ...)
         (lambda () (store-close store)))))))

;;; --------------------------------------------------------------------
;;; SPARQL Operations
;;; --------------------------------------------------------------------

(define* (store-query store sparql #:key (buffer-size (* 1024 1024)))
  "Execute a SPARQL query and return JSON results as a string.
   BUFFER-SIZE defaults to 1MB."
  (let* ((sparql-ptr (string->pointer sparql))
         (buffer (make-bytevector buffer-size 0))
         (buffer-ptr (bytevector->pointer buffer))
         (result (ffi-store-query (store-ptr store)
                                   sparql-ptr
                                   buffer-ptr
                                   buffer-size)))
    (check-result result)
    (pointer->string buffer-ptr)))

(define (store-update store sparql)
  "Execute a SPARQL UPDATE query (INSERT/DELETE)."
  (let* ((sparql-ptr (string->pointer sparql))
         (result (ffi-store-update (store-ptr store) sparql-ptr)))
    (check-result result)
    #t))

;;; --------------------------------------------------------------------
;;; Quad Operations
;;; --------------------------------------------------------------------

(define* (store-insert-quad store subject predicate object #:key graph)
  "Insert a single quad into the store.
   SUBJECT, PREDICATE, OBJECT are URI strings.
   GRAPH is optional (defaults to default graph)."
  (let* ((s-ptr (string->pointer subject))
         (p-ptr (string->pointer predicate))
         (o-ptr (string->pointer object))
         (g-ptr (if graph (string->pointer graph) %null-pointer))
         (result (ffi-store-insert-quad (store-ptr store)
                                         s-ptr p-ptr o-ptr g-ptr)))
    (check-result result)
    #t))

(define* (store-delete-quad store subject predicate object #:key graph)
  "Delete a single quad from the store."
  (let* ((s-ptr (string->pointer subject))
         (p-ptr (string->pointer predicate))
         (o-ptr (string->pointer object))
         (g-ptr (if graph (string->pointer graph) %null-pointer))
         (result (ffi-store-delete-quad (store-ptr store)
                                         s-ptr p-ptr o-ptr g-ptr)))
    (check-result result)
    #t))

;;; --------------------------------------------------------------------
;;; Serialization
;;; --------------------------------------------------------------------

(define* (store-dump-graph store #:key graph (format "turtle") (buffer-size (* 1024 1024)))
  "Dump a named graph to RDF format.
   FORMAT is one of: \"turtle\", \"ntriples\", \"nquads\"
   GRAPH is optional (defaults to all graphs).
   Returns the serialized RDF as a string."
  (let* ((g-ptr (if graph (string->pointer graph) %null-pointer))
         (fmt-ptr (string->pointer format))
         (buffer (make-bytevector buffer-size 0))
         (buffer-ptr (bytevector->pointer buffer))
         (result (ffi-store-dump-graph (store-ptr store)
                                        g-ptr fmt-ptr
                                        buffer-ptr buffer-size)))
    (check-result result)
    (pointer->string buffer-ptr)))

(define* (store-load-graph store data #:key graph (format "turtle"))
  "Load RDF data into a named graph.
   DATA is the RDF content as a string.
   FORMAT is one of: \"turtle\", \"ntriples\", \"nquads\"
   GRAPH is optional (defaults to default graph)."
  (let* ((g-ptr (if graph (string->pointer graph) %null-pointer))
         (fmt-ptr (string->pointer format))
         (data-ptr (string->pointer data))
         (result (ffi-store-load-graph (store-ptr store)
                                        g-ptr fmt-ptr data-ptr)))
    (check-result result)
    #t))

;;; --------------------------------------------------------------------
;;; Statistics
;;; --------------------------------------------------------------------

(define (store-count store)
  "Get the number of quads in the store."
  (check-result (ffi-store-count (store-ptr store))))

(define (store-empty? store)
  "Check if the store is empty."
  (let ((result (ffi-store-is-empty (store-ptr store))))
    (check-result result)
    (= result 1)))

;;; --------------------------------------------------------------------
;;; Named Graph Operations
;;; --------------------------------------------------------------------

(define* (store-list-graphs store #:key (buffer-size (* 1024 1024)))
  "List all named graphs in the store.
   Returns a list of graph URI strings."
  (let* ((buffer (make-bytevector buffer-size 0))
         (buffer-ptr (bytevector->pointer buffer))
         (result (ffi-store-list-graphs (store-ptr store)
                                         buffer-ptr buffer-size)))
    (check-result result)
    (let ((json-str (pointer->string buffer-ptr)))
      (if (string=? json-str "[]")
          '()
          (json-string->scm json-str)))))

(define (store-graph-exists? store graph)
  "Check if a named graph exists in the store.
   GRAPH is the graph URI string."
  (let* ((g-ptr (string->pointer graph))
         (result (ffi-store-graph-exists (store-ptr store) g-ptr)))
    (check-result result)
    (= result 1)))

(define (store-create-graph store graph)
  "Create an empty named graph in the store.
   GRAPH is the graph URI string."
  (let* ((g-ptr (string->pointer graph))
         (result (ffi-store-create-graph (store-ptr store) g-ptr)))
    (check-result result)
    #t))

(define (store-drop-graph store graph)
  "Drop a named graph and all its triples.
   GRAPH is the graph URI string."
  (let* ((g-ptr (string->pointer graph))
         (result (ffi-store-drop-graph (store-ptr store) g-ptr)))
    (check-result result)
    #t))

(define (store-clear-graph store graph)
  "Clear all triples in a named graph (graph name remains).
   GRAPH is the graph URI string."
  (let* ((g-ptr (string->pointer graph))
         (result (ffi-store-clear-graph (store-ptr store) g-ptr)))
    (check-result result)
    #t))

(define (store-graph-count store graph)
  "Count the number of quads in a specific named graph.
   GRAPH is the graph URI string."
  (let* ((g-ptr (string->pointer graph))
         (result (ffi-store-graph-count (store-ptr store) g-ptr)))
    (check-result result)
    result))

;;; --------------------------------------------------------------------
;;; UUID Generation
;;; --------------------------------------------------------------------

(define ffi-uuid-generate
  (foreign-library-function libxm-ffi "xm_uuid_generate"
                            #:return-type int
                            #:arg-types (list '* size_t)))

(define (generate-uuid)
  "Generate a new UUID v4 string."
  (let* ((buffer (make-bytevector 64 0))
         (buffer-ptr (bytevector->pointer buffer))
         (result (ffi-uuid-generate buffer-ptr 64)))
    (check-result result)
    (pointer->string buffer-ptr)))

;;; --------------------------------------------------------------------
;;; JSON Parsing (for SPARQL results)
;;; --------------------------------------------------------------------

(define (json-string->scm str)
  "Parse a JSON string to Scheme objects.
   Objects become alists, arrays become lists."
  (let ((port (open-input-string str)))
    (json-read port)))

(define (json-read port)
  "Read a JSON value from PORT."
  (skip-whitespace port)
  (let ((c (peek-char port)))
    (cond
     ((eof-object? c) c)
     ((char=? c #\{) (json-read-object port))
     ((char=? c #\[) (json-read-array port))
     ((char=? c #\") (json-read-string port))
     ((or (char=? c #\-) (char-numeric? c)) (json-read-number port))
     ((char=? c #\t) (json-read-true port))
     ((char=? c #\f) (json-read-false port))
     ((char=? c #\n) (json-read-null port))
     (else (error "Invalid JSON" c)))))

(define (skip-whitespace port)
  (let loop ()
    (let ((c (peek-char port)))
      (when (and (not (eof-object? c))
                 (char-whitespace? c))
        (read-char port)
        (loop)))))

(define (json-read-object port)
  (read-char port) ; consume {
  (skip-whitespace port)
  (if (char=? (peek-char port) #\})
      (begin (read-char port) '())
      (let loop ((pairs '()))
        (skip-whitespace port)
        (let* ((key (json-read-string port)))
          (skip-whitespace port)
          (read-char port) ; consume :
          (skip-whitespace port)
          (let ((value (json-read port)))
            (skip-whitespace port)
            (let ((c (read-char port)))
              (cond
               ((char=? c #\}) (reverse (cons (cons key value) pairs)))
               ((char=? c #\,) (loop (cons (cons key value) pairs)))
               (else (error "Expected , or } in object")))))))))

(define (json-read-array port)
  (read-char port) ; consume [
  (skip-whitespace port)
  (if (char=? (peek-char port) #\])
      (begin (read-char port) '())
      (let loop ((items '()))
        (skip-whitespace port)
        (let ((item (json-read port)))
          (skip-whitespace port)
          (let ((c (read-char port)))
            (cond
             ((char=? c #\]) (reverse (cons item items)))
             ((char=? c #\,) (loop (cons item items)))
             (else (error "Expected , or ] in array"))))))))

(define (json-read-string port)
  (read-char port) ; consume opening "
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (cond
       ((char=? c #\") (list->string (reverse chars)))
       ((char=? c #\\)
        (let ((escaped (read-char port)))
          (loop (cons (case escaped
                        ((#\n) #\newline)
                        ((#\t) #\tab)
                        ((#\r) #\return)
                        ((#\") #\")
                        ((#\\) #\\)
                        ((#\/) #\/)
                        (else escaped))
                      chars))))
       (else (loop (cons c chars)))))))

(define (json-read-number port)
  (let loop ((chars '()))
    (let ((c (peek-char port)))
      (if (and (not (eof-object? c))
               (or (char-numeric? c)
                   (char=? c #\-)
                   (char=? c #\+)
                   (char=? c #\.)
                   (char=? c #\e)
                   (char=? c #\E)))
          (begin
            (read-char port)
            (loop (cons c chars)))
          (string->number (list->string (reverse chars)))))))

(define (json-read-true port)
  (read-char port) (read-char port) (read-char port) (read-char port) ; true
  #t)

(define (json-read-false port)
  (read-char port) (read-char port) (read-char port) (read-char port) (read-char port) ; false
  #f)

(define (json-read-null port)
  (read-char port) (read-char port) (read-char port) (read-char port) ; null
  '())
