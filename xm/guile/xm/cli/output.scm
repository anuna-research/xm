;;; xm/cli/output.scm --- Output formatting for CLI
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This module handles JSON and human-readable output formatting
;;; per SPEC-029 Section 5.5.

(define-module (xm cli output)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:export (;; Output functions
            output-result
            output-error
            output-ndjson
            output-progress

            ;; JSON utilities
            scm->json
            json->scm

            ;; Human-readable formatting
            format-node
            format-link
            format-session
            format-capability
            format-table))

;;; --------------------------------------------------------------------
;;; JSON Serialization
;;; --------------------------------------------------------------------

(define (scm->json obj)
  "Convert a Scheme object to JSON string."
  (cond
   ;; Null
   ((null? obj) "null")

   ;; Boolean
   ((eq? obj #t) "true")
   ((eq? obj #f) "false")

   ;; Number
   ((number? obj)
    (if (exact? obj)
        (number->string obj)
        (let ((s (number->string obj)))
          ;; Ensure decimal point for floats
          (if (string-index s #\.)
              s
              (string-append s ".0")))))

   ;; String
   ((string? obj)
    (string-append "\"" (json-escape-string obj) "\""))

   ;; Symbol (convert to string)
   ((symbol? obj)
    (scm->json (symbol->string obj)))

   ;; Dotted pair (non-list pair) -> single-key object
   ;; This must come BEFORE the list? check since dotted pairs are pairs but not lists
   ((and (pair? obj) (not (list? obj)))
    (string-append
     "{"
     (scm->json (car obj))
     ":"
     (scm->json (cdr obj))
     "}"))

   ;; List (array or alist)
   ((list? obj)
    (if (alist? obj)
        ;; Alist -> object
        ;; Handle both dotted pairs (a . b) and list pairs (a b c...) as alist entries
        (string-append
         "{"
         (string-join
          (map (lambda (entry)
                 (let ((key (car entry))
                       (value (if (and (pair? (cdr entry)) (null? (cddr entry)))
                                  ;; (key value) form - take second element
                                  (cadr entry)
                                  ;; (key . value) or (key v1 v2...) - take cdr
                                  (cdr entry))))
                   (string-append (scm->json key)
                                  ":"
                                  (scm->json value))))
               obj)
          ",")
         "}")
        ;; Regular list -> array
        (string-append
         "["
         (string-join (map scm->json obj) ",")
         "]")))

   ;; Vector -> array
   ((vector? obj)
    (scm->json (vector->list obj)))

   ;; Hash table -> object
   ((hash-table? obj)
    (scm->json (hash-map->list cons obj)))

   ;; Unknown - convert to string
   (else
    (scm->json (format #f "~a" obj)))))

(define (json-escape-string str)
  "Escape special characters in a string for JSON."
  (let loop ((chars (string->list str)) (acc '()))
    (if (null? chars)
        (list->string (reverse acc))
        (let ((char (car chars)))
          (loop (cdr chars)
                (append
                 (reverse
                  (string->list
                   (case char
                     ((#\") "\\\"")
                     ((#\\) "\\\\")
                     ((#\newline) "\\n")
                     ((#\return) "\\r")
                     ((#\tab) "\\t")
                     (else (string char)))))
                 acc))))))

(define (json->scm str)
  "Parse a JSON string to Scheme object.
   Note: This is a simplified parser for basic JSON."
  ;; For a full implementation, use a proper JSON library
  ;; This is a placeholder that handles simple cases
  (cond
   ((string=? str "null") '())
   ((string=? str "true") #t)
   ((string=? str "false") #f)
   ((string-prefix? "\"" str)
    (substring str 1 (- (string-length str) 1)))
   ((or (string-prefix? "[" str) (string-prefix? "{" str))
    ;; Complex JSON - would need full parser
    str)
   (else
    (string->number str))))

;;; --------------------------------------------------------------------
;;; Output Functions
;;; --------------------------------------------------------------------

(define* (output-result data opts #:key ok meta)
  "Output a successful result in JSON or human format."
  (let ((json-mode (or (assoc-ref opts "json")
                       (assoc-ref opts 'json))))
    (if json-mode
        ;; JSON output - ok defaults to true unless explicitly passed as #f
        (let ((result `((ok . #t)
                        (data . ,data)
                        ,@(if meta `((meta . ,meta)) '()))))
          (display (scm->json result))
          (newline))
        ;; Human output
        (display-human data))))

(define* (output-error code message details opts #:key meta)
  "Output an error in JSON or human format to stderr."
  (let ((json-mode (or (assoc-ref opts "json")
                       (assoc-ref opts 'json)))
        (port (current-error-port)))
    (if json-mode
        ;; JSON error
        (let ((result `((ok . #f)
                        (error . ((code . ,code)
                                  (message . ,message)
                                  (details . ,details)))
                        ,@(if meta `((meta . ,meta)) '()))))
          (display (scm->json result) port)
          (newline port))
        ;; Human error
        (begin
          (format port "Error: ~a\n" message)
          (when details
            (format port "  ~a\n" details))))))

(define (output-ndjson data-list opts)
  "Output a list of items as newline-delimited JSON (NDJSON)."
  (for-each
   (lambda (item)
     (display (scm->json item))
     (newline))
   data-list))

(define* (output-progress message current total #:key (port (current-error-port)))
  "Output a progress indicator to stderr."
  (let* ((pct (if (> total 0) (quotient (* current 100) total) 0))
         (bar-width 32)
         (filled (quotient (* pct bar-width) 100))
         (bar (string-append
               (make-string filled #\x2588)  ; filled block
               (make-string (- bar-width filled) #\x2591))))  ; light block
    (format port "\r  ~a: [~a] ~a% (~a / ~a)"
            message bar pct current total)
    (force-output port)))

;;; --------------------------------------------------------------------
;;; Human-Readable Formatting
;;; --------------------------------------------------------------------

(define (display-human data)
  "Display data in human-readable format."
  (cond
   ;; Alist with known structure
   ((and (list? data) (pair? data) (pair? (car data)))
    (display-alist data))
   ;; List of items
   ((list? data)
    (for-each (lambda (item)
                (display-human item)
                (newline))
              data))
   ;; Simple value
   (else
    (display data)
    (newline))))

(define (display-alist alist)
  "Display an alist in human-readable format."
  (for-each
   (lambda (pair)
     (format #t "  ~a: ~a\n" (car pair) (format-value (cdr pair))))
   alist))

(define (format-value val)
  "Format a value for human-readable output."
  (cond
   ;; Null/empty list
   ((null? val) "(none)")
   ;; Boolean
   ((eq? val #t) "true")
   ((eq? val #f) "false")
   ;; Nested alist (list of pairs with symbol/string keys)
   ((and (list? val) (pair? val) (pair? (car val)))
    (string-join
     (map (lambda (p)
            (format #f "~a=~a" (car p) (cdr p)))
          val)
     ", "))
   ;; Simple list
   ((list? val)
    (string-join (map (lambda (x) (format #f "~a" x)) val) ", "))
   ;; Everything else
   (else (format #f "~a" val))))

(define (format-node node)
  "Format a node for human-readable output."
  (let ((id (assoc-ref node 'id))
        (type (assoc-ref node 'type))
        (props (assoc-ref node 'properties)))
    (format #t "Node: ~a\n" id)
    (format #t "Type: ~a\n" type)
    (when props
      (format #t "\nProperties:\n")
      (for-each
       (lambda (p)
         (format #t "  ~a: ~a\n" (car p) (cdr p)))
       props))))

(define (format-link link)
  "Format a link for human-readable output."
  (let ((id (assoc-ref link 'id))
        (source (assoc-ref link 'source))
        (predicate (assoc-ref link 'predicate))
        (target (assoc-ref link 'target)))
    (format #t "Link: ~a\n" id)
    (format #t "  ~a -> ~a -> ~a\n" source predicate target)))

(define (format-session session)
  "Format a session for human-readable output."
  (let ((id (assoc-ref session 'session-id))
        (agent (assoc-ref session 'agent))
        (purpose (assoc-ref session 'purpose))
        (active (assoc-ref session 'active)))
    (format #t "Session: ~a\n" id)
    (format #t "  Agent: ~a\n" agent)
    (format #t "  Purpose: ~a\n" purpose)
    (format #t "  Status: ~a\n" (if active "active" "ended"))))

(define (format-capability cap)
  "Format a capability for human-readable output."
  (let ((id (assoc-ref cap 'cap_ref))
        (graphs (assoc-ref cap 'graphs))
        (perms (assoc-ref cap 'permissions))
        (expires (assoc-ref cap 'expires)))
    (format #t "Capability: ~a\n" id)
    (format #t "  Graphs: ~a\n" (string-join graphs ", "))
    (format #t "  Permissions: ~a\n" (string-join (map symbol->string perms) ", "))
    (when expires
      (format #t "  Expires: ~a\n" expires))))

(define* (format-table rows #:key headers)
  "Format data as a table."
  (when headers
    (display (string-join headers "\t"))
    (newline)
    (display (make-string 60 #\-))
    (newline))
  (for-each
   (lambda (row)
     (display (string-join (map (lambda (x) (format #f "~a" x)) row) "\t"))
     (newline))
   rows))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (alist? obj)
  "Check if OBJ is an association list.
   An alist is a list where each element is a pair with a symbol or string key."
  (and (list? obj)
       (pair? obj)
       (every (lambda (entry)
                (and (pair? entry)
                     (or (symbol? (car entry))
                         (string? (car entry)))))
              obj)))

(define (every pred lst)
  "Return #t if PRED returns true for every element of LST."
  (or (null? lst)
      (and (pred (car lst))
           (every pred (cdr lst)))))

(define (string-prefix? prefix str)
  "Check if STR starts with PREFIX."
  (and (>= (string-length str) (string-length prefix))
       (string=? prefix (substring str 0 (string-length prefix)))))

(define (string-index str char)
  "Find index of CHAR in STR."
  (let loop ((i 0))
    (cond
     ((>= i (string-length str)) #f)
     ((char=? (string-ref str i) char) i)
     (else (loop (+ i 1))))))
