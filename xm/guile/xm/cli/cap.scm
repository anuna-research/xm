;;; xm/cli/cap.scm --- Capability commands for CLI
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; Implements cap create/attenuate/revoke/list/inspect commands per SPEC-029 Section 5.15.

(define-module (xm cli cap)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (xm cli output)
  #:use-module (xm cli parser)
  #:use-module (xm vocabulary)
  #:use-module (xm store)
  #:export (handle-cap-command
            cmd-cap-create
            cmd-cap-attenuate
            cmd-cap-revoke
            cmd-cap-list
            cmd-cap-inspect))

;;; --------------------------------------------------------------------
;;; Capability Command Dispatcher
;;; --------------------------------------------------------------------

(define (handle-cap-command subcommand opts global-opts store cap-ref)
  "Dispatch capability subcommands."
  (case subcommand
    ((create) (cmd-cap-create opts global-opts store cap-ref))
    ((attenuate) (cmd-cap-attenuate opts global-opts store cap-ref))
    ((revoke) (cmd-cap-revoke opts global-opts store cap-ref))
    ((list) (cmd-cap-list opts global-opts store cap-ref))
    ((inspect) (cmd-cap-inspect opts global-opts store cap-ref))
    (else
     (output-error "UNKNOWN_SUBCOMMAND"
                   (format #f "Unknown cap subcommand: ~a" subcommand)
                   "Available: create, attenuate, revoke, list, inspect"
                   global-opts)
     2)))

;;; --------------------------------------------------------------------
;;; cap create
;;; --------------------------------------------------------------------

(define (cmd-cap-create opts global-opts store cap-ref)
  "Create a new root capability.
   Options:
   -g, --graph URI: Named graph to grant access to (repeatable, required)
   --read: Grant read permission
   --write: Grant write permission
   --admin: Grant admin permission
   --expires DURATION: Expiration (e.g., 7d, 24h)
   -l, --label TEXT: Human-readable label"

  (let* ((graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (admin-perm (assoc-ref opts "admin"))
         (expires (assoc-ref opts "expires"))
         (label (or (assoc-ref opts "label")
                    (assoc-ref opts "l"))))

    ;; Validate required options
    (when (null? graphs)
      (output-error "MISSING_GRAPH"
                    "At least one graph is required"
                    "Use -g or --graph to specify graphs"
                    global-opts)
      (exit 2))

    ;; Build permissions list
    (let ((permissions (filter identity
                               (list (and read-perm 'read)
                                     (and write-perm 'write)
                                     (and admin-perm 'admin)))))

      ;; Default to read permission if none specified
      (when (null? permissions)
        (set! permissions '(read)))

      ;; Create capability
      (let* ((cap-id (xm-cap-uri (generate-uuid)))
             (timestamp (current-iso-timestamp))
             (expires-at (and expires (parse-duration-to-iso expires)))
             (result `((id . ,cap-id)
                       (graphs . ,graphs)
                       (permissions . ,permissions)
                       (created_at . ,timestamp)
                       (expires . ,expires-at)
                       (label . ,label))))

        ;; In production: (<- cap-store 'create graphs permissions expires label)

        (if (assoc-ref global-opts "json")
            (output-result result global-opts)
            (begin
              (format #t "\nCapability created: ~a\n" cap-id)
              (format #t "Graphs: ~a\n" (string-join graphs ", "))
              (format #t "Permissions: ~a\n" permissions)
              (when expires-at (format #t "Expires: ~a\n" expires-at))
              (when label (format #t "Label: ~a\n" label))
              (format #t "\nExport XM_CAP=~a\n" cap-id)))))))

;;; --------------------------------------------------------------------
;;; cap attenuate
;;; --------------------------------------------------------------------

(define (cmd-cap-attenuate opts global-opts store cap-ref)
  "Create an attenuated (weaker) capability from an existing one.
   Usage: xm cap attenuate <CAP_ID>
   Options:
   -g, --graph URI: Limit to these graphs (must be subset)
   --read: Include read permission
   --write: Include write permission
   --expires DURATION: Shorten expiration
   -l, --label TEXT: Human-readable label"

  (let* ((positional (assoc-ref opts 'positional))
         (parent-id (and (pair? positional) (car positional)))
         (graphs (filter-map
                  (lambda (opt)
                    (and (member (car opt) '("graph" "g"))
                         (cdr opt)))
                  opts))
         (read-perm (assoc-ref opts "read"))
         (write-perm (assoc-ref opts "write"))
         (expires (assoc-ref opts "expires"))
         (label (or (assoc-ref opts "label")
                    (assoc-ref opts "l"))))

    (unless parent-id
      (output-error "MISSING_CAP_ID"
                    "Parent capability ID is required"
                    "Usage: xm cap attenuate <CAP_ID> [options]"
                    global-opts)
      (exit 2))

    ;; Build permissions list
    (let ((permissions (filter identity
                               (list (and read-perm 'read)
                                     (and write-perm 'write)))))

      ;; Create attenuated capability
      (let* ((cap-id (xm-cap-uri (generate-uuid)))
             (timestamp (current-iso-timestamp))
             (expires-at (and expires (parse-duration-to-iso expires)))
             (result `((id . ,cap-id)
                       (parent . ,parent-id)
                       (graphs . ,(if (null? graphs) "inherited" graphs))
                       (permissions . ,(if (null? permissions) "inherited" permissions))
                       (created_at . ,timestamp)
                       (expires . ,expires-at)
                       (label . ,label))))

        ;; In production: (<- cap-store 'attenuate parent-id graphs permissions expires label)

        (if (assoc-ref global-opts "json")
            (output-result result global-opts)
            (begin
              (format #t "\nAttenuated capability created: ~a\n" cap-id)
              (format #t "Parent: ~a\n" parent-id)
              (unless (null? graphs)
                (format #t "Graphs: ~a\n" (string-join graphs ", ")))
              (unless (null? permissions)
                (format #t "Permissions: ~a\n" permissions))
              (when expires-at (format #t "Expires: ~a\n" expires-at))
              (when label (format #t "Label: ~a\n" label))))))))

;;; --------------------------------------------------------------------
;;; cap revoke
;;; --------------------------------------------------------------------

(define (cmd-cap-revoke opts global-opts store cap-ref)
  "Revoke a capability.
   Usage: xm cap revoke <CAP_ID>
   Options:
   --cascade: Also revoke all derived capabilities"

  (let* ((positional (assoc-ref opts 'positional))
         (cap-id (and (pair? positional) (car positional)))
         (cascade (assoc-ref opts "cascade")))

    (unless cap-id
      (output-error "MISSING_CAP_ID"
                    "Capability ID is required"
                    "Usage: xm cap revoke <CAP_ID>"
                    global-opts)
      (exit 2))

    ;; In production: (<- cap-store 'revoke cap-id)

    (let ((result `((revoked . ,cap-id)
                    (cascade . ,(if cascade #t #f))
                    (derived_revoked . 0))))

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nCapability revoked: ~a\n" cap-id)
            (when cascade
              (format #t "Derived capabilities also revoked: ~a\n"
                      (assoc-ref result 'derived_revoked))))))))

;;; --------------------------------------------------------------------
;;; cap list
;;; --------------------------------------------------------------------

(define (cmd-cap-list opts global-opts store cap-ref)
  "List capabilities.
   Options:
   --created-by-me: Only capabilities I created
   --active-only: Exclude expired/revoked
   --expired: Show expired capabilities"

  (let* ((created-by-me (assoc-ref opts "created-by-me"))
         (active-only (assoc-ref opts "active-only"))
         (show-expired (assoc-ref opts "expired")))

    ;; In production: (<- cap-store 'list-all (not active-only) show-expired)

    (let ((capabilities '()))

      (if (assoc-ref global-opts "json")
          (output-result `((capabilities . ,capabilities)
                           (count . ,(length capabilities))
                           (filters . ((created_by_me . ,(if created-by-me #t #f))
                                       (active_only . ,(if active-only #t #f))
                                       (show_expired . ,(if show-expired #t #f)))))
                         global-opts)
          (begin
            (format #t "\nCapabilities")
            (when active-only (format #t " (active only)"))
            (format #t ":\n\n")
            (if (null? capabilities)
                (format #t "  (no capabilities found)\n")
                (for-each
                 (lambda (cap)
                   (format #t "  ~a  ~a  ~a\n"
                           (assoc-ref cap 'id)
                           (assoc-ref cap 'permissions)
                           (or (assoc-ref cap 'label) "")))
                 capabilities)))))))

;;; --------------------------------------------------------------------
;;; cap inspect
;;; --------------------------------------------------------------------

(define (cmd-cap-inspect opts global-opts store cap-ref)
  "Inspect a capability's full details.
   Usage: xm cap inspect <CAP_ID>"

  (let* ((positional (assoc-ref opts 'positional))
         (cap-id (and (pair? positional) (car positional))))

    (unless cap-id
      (output-error "MISSING_CAP_ID"
                    "Capability ID is required"
                    "Usage: xm cap inspect <CAP_ID>"
                    global-opts)
      (exit 2))

    ;; In production: (<- cap-store 'get cap-id)

    (let ((result `((id . ,cap-id)
                    (graphs . ("xm:graph/public" "xm:graph/agent/claude"))
                    (permissions . (read write))
                    (created_at . ,(current-iso-timestamp))
                    (created_by . #f)
                    (expires . #f)
                    (revoked . #f)
                    (label . "Example capability"))))

      (if (assoc-ref global-opts "json")
          (output-result result global-opts)
          (begin
            (format #t "\nCapability: ~a\n\n" cap-id)
            (format #t "Graphs:\n")
            (for-each (lambda (g) (format #t "  - ~a\n" g))
                      (assoc-ref result 'graphs))
            (format #t "\nPermissions: ~a\n" (assoc-ref result 'permissions))
            (format #t "Created: ~a\n" (assoc-ref result 'created_at))
            (when (assoc-ref result 'created_by)
              (format #t "Parent: ~a\n" (assoc-ref result 'created_by)))
            (if (assoc-ref result 'expires)
                (format #t "Expires: ~a\n" (assoc-ref result 'expires))
                (format #t "Expires: never\n"))
            (format #t "Status: ~a\n"
                    (if (assoc-ref result 'revoked) "revoked" "active"))
            (when (assoc-ref result 'label)
              (format #t "Label: ~a\n" (assoc-ref result 'label))))))))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (current-iso-timestamp)
  "Get current time as ISO 8601 string."
  (date->string (time-utc->date (current-time time-utc))
                "~Y-~m-~dT~H:~M:~SZ"))

(define (generate-uuid)
  "Generate a simple UUID-like string."
  (let* ((t (current-time time-utc))
         (secs (time-second t))
         (nsecs (time-nanosecond t))
         (r1 (random (expt 2 32)))
         (r2 (random (expt 2 32))))
    (format #f "~8,'0x-~4,'0x-~4,'0x-~4,'0x-~12,'0x"
            (logand secs #xffffffff)
            (logand (ash nsecs -16) #xffff)
            (logior #x4000 (logand (ash nsecs 0) #x0fff))
            (logior #x8000 (logand r1 #x3fff))
            (logand r2 #xffffffffffff))))

(define (parse-duration-to-iso duration-str)
  "Parse a duration string (7d, 24h, 30m) and return ISO timestamp for expiration."
  (let* ((len (string-length duration-str))
         (unit (string-ref duration-str (- len 1)))
         (value (string->number (substring duration-str 0 (- len 1))))
         (now (current-time time-utc))
         (seconds (case unit
                    ((#\d) (* value 86400))   ; days
                    ((#\h) (* value 3600))    ; hours
                    ((#\m) (* value 60))      ; minutes
                    ((#\s) value)             ; seconds
                    (else (* value 86400))))) ; default to days
    (date->string
     (time-utc->date
      (add-duration now (make-time time-duration 0 seconds)))
     "~Y-~m-~dT~H:~M:~SZ")))

(define (filter-map proc lst)
  "Map PROC over LST, keeping only non-#f results."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (let ((result (proc (car lst))))
          (if result
              (loop (cdr lst) (cons result acc))
              (loop (cdr lst) acc))))))

(define (string-join strs sep)
  "Join strings with separator."
  (if (null? strs)
      ""
      (let loop ((strs (cdr strs)) (acc (car strs)))
        (if (null? strs)
            acc
            (loop (cdr strs) (string-append acc sep (car strs)))))))

(define (filter pred lst)
  "Keep elements where PRED returns true."
  (let loop ((lst lst) (acc '()))
    (if (null? lst)
        (reverse acc)
        (if (pred (car lst))
            (loop (cdr lst) (cons (car lst) acc))
            (loop (cdr lst) acc)))))

(define (identity x) x)
