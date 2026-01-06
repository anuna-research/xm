;;; xm/cli/parser.scm --- Command-line argument parsing
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module provides argument parsing following CLI guidelines (clig.dev).

(define-module (xm cli parser)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)  ; let-values
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:export (parse-args
            parse-key-value
            make-option-spec
            option-spec?
            option-spec-short
            option-spec-long
            option-spec-type
            option-spec-required
            option-spec-default
            option-spec-multiple
            option-spec-description))

;;; --------------------------------------------------------------------
;;; Option Specification
;;; --------------------------------------------------------------------

(define-record-type <option-spec>
  (make-option-spec short long type required default multiple description)
  option-spec?
  (short option-spec-short)           ; Short flag (e.g., #\t)
  (long option-spec-long)             ; Long flag (e.g., "type")
  (type option-spec-type)             ; 'flag | 'string | 'number
  (required option-spec-required)     ; #t if required
  (default option-spec-default)       ; Default value
  (multiple option-spec-multiple)     ; #t if can be repeated
  (description option-spec-description)) ; Help text

;;; --------------------------------------------------------------------
;;; Global Options (from SPEC-029 Section 5.2)
;;; --------------------------------------------------------------------

(define *global-options*
  (list
   (make-option-spec #\h "help" 'flag #f #f #f
                     "Show help for command")
   (make-option-spec #f "version" 'flag #f #f #f
                     "Show version and exit")
   (make-option-spec #\d "debug" 'flag #f #f #f
                     "Include debug information")
   (make-option-spec #\q "quiet" 'flag #f #f #f
                     "Suppress non-essential output")
   (make-option-spec #\v "verbose" 'flag #f #f #f
                     "Show detailed progress")
   (make-option-spec #f "json" 'flag #f #f #f
                     "Output in JSON format")
   (make-option-spec #f "no-color" 'flag #f #f #f
                     "Disable colored output")
   (make-option-spec #f "no-input" 'flag #f #f #f
                     "Disable interactive prompts")
   (make-option-spec #f "store" 'string #f #f #f
                     "Path to xm store")
   (make-option-spec #f "session" 'string #f #f #f
                     "Use existing session")
   (make-option-spec #f "cap" 'string #f #f #f
                     "Capability reference")
   (make-option-spec #f "remote" 'string #f #f #f
                     "Remote xm daemon URI")))

;;; --------------------------------------------------------------------
;;; Argument Parsing
;;; --------------------------------------------------------------------

;; Global option names that should always go to global-opts regardless of position
(define *global-option-names*
  '("help" "h" "version" "debug" "d" "quiet" "q" "verbose" "v"
    "json" "no-color" "no-input" "store" "session" "cap" "remote"))

(define (global-option? name)
  "Check if NAME is a global option."
  (member name *global-option-names*))

(define (parse-args args)
  "Parse command-line arguments into a structured result.
   Returns an alist with:
   - global: global option values
   - command: command name (symbol)
   - subcommand: subcommand name (symbol) or #f
   - options: command-specific options
   - positional: positional arguments"

  (let loop ((args (cdr args))  ; Skip program name
             (global-opts '())
             (command #f)
             (subcommand #f)
             (cmd-opts '())
             (positional '())
             (in-global #t))

    (if (null? args)
        `((global . ,(reverse global-opts))
          (command . ,command)
          (subcommand . ,subcommand)
          (options . ,(reverse cmd-opts))
          (positional . ,(reverse positional)))

        (let ((arg (car args))
              (rest (cdr args)))

          (cond
           ;; End of options marker: --
           ((string=? arg "--")
            (loop rest global-opts command subcommand cmd-opts positional in-global))

           ;; Long option: --name or --name=value
           ((string-prefix? "--" arg)
            (let-values (((name value rest*) (parse-long-option arg rest)))
              ;; Global options go to global-opts regardless of position
              (if (or in-global (global-option? name))
                  (loop rest* (cons (cons name value) global-opts)
                        command subcommand cmd-opts positional in-global)
                  (loop rest* global-opts command subcommand
                        (cons (cons name value) cmd-opts) positional #f))))

           ;; Short option: -x or -xyz (combined)
           ((and (string-prefix? "-" arg)
                 (> (string-length arg) 1)
                 (not (string=? arg "-")))
            (let-values (((opts rest*) (parse-short-options arg rest)))
              ;; Check each option - global ones go to global-opts
              (let-values (((global-from-opts cmd-from-opts)
                            (partition-options opts)))
                (loop rest*
                      (append (reverse global-from-opts) global-opts)
                      command subcommand
                      (append (reverse cmd-from-opts) cmd-opts)
                      positional
                      in-global))))

           ;; Command/subcommand
           ((not command)
            (loop rest global-opts (string->symbol arg) #f '() '() #f))

           ((not subcommand)
            ;; Check if this looks like a subcommand (not starting with -)
            (if (or (string-prefix? "-" arg)
                    (string-index arg #\=))
                ;; It's an option, not a subcommand
                (loop (cons arg rest) global-opts command #f cmd-opts positional #f)
                ;; It's a subcommand
                (loop rest global-opts command (string->symbol arg) '() '() #f)))

           ;; Positional argument
           (else
            (loop rest global-opts command subcommand cmd-opts
                  (cons arg positional) #f)))))))

(define (partition-options opts)
  "Partition options into global and command-specific.
   Returns (values global-opts cmd-opts)."
  (let loop ((opts opts) (global '()) (cmd '()))
    (if (null? opts)
        (values (reverse global) (reverse cmd))
        (let ((opt (car opts)))
          (if (global-option? (car opt))
              (loop (cdr opts) (cons opt global) cmd)
              (loop (cdr opts) global (cons opt cmd)))))))

;; Known flag options (take no value)
(define *flag-options*
  '("help" "h" "version" "debug" "d" "quiet" "q" "verbose" "v"
    "json" "no-color" "no-input" "dry-run" "n" "force" "f"
    "include-backlinks" "b" "cascade" "active-only"
    "created-by-me" "expired" "replay"))

(define (flag-option? name)
  "Check if NAME is a known boolean flag option."
  (member name *flag-options*))

(define (parse-long-option arg rest)
  "Parse a long option (--name or --name=value).
   Returns (values name value remaining-args)."
  (let ((eq-pos (string-index arg #\=)))
    (if eq-pos
        ;; --name=value
        (values (substring arg 2 eq-pos)
                (substring arg (+ eq-pos 1))
                rest)
        ;; --name (check if next arg is value)
        (let ((name (substring arg 2)))
          (if (or (null? rest)
                  (string-prefix? "-" (car rest))
                  (flag-option? name))  ; Known flags don't take values
              ;; No value - it's a flag
              (values name #t rest)
              ;; Next arg is value
              (values name (car rest) (cdr rest)))))))

(define (parse-short-options arg rest)
  "Parse short options (-x or -xyz).
   Returns (values option-list remaining-args)."
  (let* ((chars (string->list (substring arg 1)))
         (opts '()))
    (let loop ((chars chars) (rest rest))
      (if (null? chars)
          (values (reverse opts) rest)
          (let* ((char (car chars))
                 (name (string char)))
            (if (null? (cdr chars))
                ;; Last char - might have value
                (if (or (null? rest)
                        (string-prefix? "-" (car rest))
                        (flag-option? name))  ; Known flags don't take values
                    (values (reverse (cons (cons name #t) opts)) rest)
                    (values (reverse (cons (cons name (car rest)) opts))
                            (cdr rest)))
                ;; Not last char - it's a flag
                (loop (cdr chars) rest)))))))

;;; --------------------------------------------------------------------
;;; Key=Value Parsing
;;; --------------------------------------------------------------------

(define (parse-key-value str)
  "Parse a KEY=VALUE string into (key . value) pair."
  (let ((eq-pos (string-index str #\=)))
    (if eq-pos
        (cons (substring str 0 eq-pos)
              (substring str (+ eq-pos 1)))
        (cons str #t))))

;;; --------------------------------------------------------------------
;;; Option Lookup
;;; --------------------------------------------------------------------

(define (find-option-spec name specs)
  "Find option spec by short or long name."
  (find (lambda (spec)
          (or (and (option-spec-short spec)
                   (equal? (string (option-spec-short spec)) name))
              (equal? (option-spec-long spec) name)))
        specs))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (string-prefix? prefix str)
  "Check if STR starts with PREFIX."
  (and (>= (string-length str) (string-length prefix))
       (string=? prefix (substring str 0 (string-length prefix)))))

(define (string-index str char)
  "Find index of CHAR in STR, or #f if not found."
  (let loop ((i 0))
    (cond
     ((>= i (string-length str)) #f)
     ((char=? (string-ref str i) char) i)
     (else (loop (+ i 1))))))
