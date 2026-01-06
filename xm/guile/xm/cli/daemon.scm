;;; xm/cli/daemon.scm --- Daemon management for xm
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements the daemon management from SPEC-029 Section 5.18.
;;; The daemon provides the Goblins runtime, manages the store, and handles
;;; OCapN networking.

(define-module (xm cli daemon)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-19)
  #:use-module (xm cli output)
  #:export (;; Daemon management
            daemon-start
            daemon-stop
            daemon-restart
            daemon-status
            ensure-daemon-running

            ;; Daemon client
            daemon-connect
            daemon-send-command

            ;; Paths
            daemon-socket-path
            daemon-pid-path
            daemon-log-path))

;;; --------------------------------------------------------------------
;;; Path Configuration
;;; --------------------------------------------------------------------

(define (xm-data-dir)
  "Get xm data directory."
  (or (getenv "XM_STORE")
      (string-append (or (getenv "XDG_DATA_HOME")
                         (string-append (getenv "HOME") "/.local/share"))
                     "/xm")))

(define (daemon-socket-path)
  "Get path to daemon Unix socket."
  (string-append (xm-data-dir) "/daemon.sock"))

(define (daemon-pid-path)
  "Get path to daemon PID file."
  (string-append (xm-data-dir) "/daemon.pid"))

(define (daemon-log-path)
  "Get path to daemon log file."
  (string-append (xm-data-dir) "/daemon.log"))

;;; --------------------------------------------------------------------
;;; Daemon Status
;;; --------------------------------------------------------------------

(define (daemon-running?)
  "Check if daemon is running."
  (let ((pid-file (daemon-pid-path)))
    (and (file-exists? pid-file)
         (let ((pid (read-pid-file pid-file)))
           (and pid (process-running? pid))))))

(define (read-pid-file path)
  "Read PID from file, return #f if invalid."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (port)
          (string->number (read-line port)))))
    (lambda (key . args) #f)))

(define (process-running? pid)
  "Check if process with PID is running."
  (catch #t
    (lambda ()
      ;; Send signal 0 to check if process exists
      (zero? (system* "kill" "-0" (number->string pid))))
    (lambda (key . args) #f)))

(define (daemon-status)
  "Get daemon status as an alist."
  (if (daemon-running?)
      (let ((pid (read-pid-file (daemon-pid-path))))
        `((running . #t)
          (pid . ,pid)
          (socket . ,(daemon-socket-path))
          (store . ,(xm-data-dir))))
      `((running . #f))))

;;; --------------------------------------------------------------------
;;; Daemon Lifecycle
;;; --------------------------------------------------------------------

(define (daemon-start #:key foreground)
  "Start the xm daemon.
   If FOREGROUND is true, run in foreground instead of backgrounding."

  (when (daemon-running?)
    (error "Daemon is already running"))

  ;; Ensure data directory exists
  (ensure-directory (xm-data-dir))

  (if foreground
      ;; Run in foreground
      (run-daemon-loop)
      ;; Background the daemon
      (let ((pid (primitive-fork)))
        (cond
         ((= pid 0)
          ;; Child process - become daemon
          (setsid)  ; New session
          (chdir "/")
          ;; Redirect stdout/stderr to log
          (let ((log-port (open-file (daemon-log-path) "a")))
            (redirect-port log-port (current-output-port))
            (redirect-port log-port (current-error-port)))
          ;; Write PID file
          (call-with-output-file (daemon-pid-path)
            (lambda (port)
              (display (getpid) port)
              (newline port)))
          ;; Run daemon
          (run-daemon-loop))
         (else
          ;; Parent process - wait for daemon to be ready
          (sleep 1)
          (if (daemon-running?)
              `((started . #t)
                (pid . ,(read-pid-file (daemon-pid-path))))
              (error "Failed to start daemon")))))))

(define (daemon-stop)
  "Stop the xm daemon."
  (unless (daemon-running?)
    (error "Daemon is not running"))

  (let ((pid (read-pid-file (daemon-pid-path))))
    ;; Send SIGTERM
    (kill pid SIGTERM)
    ;; Wait for process to exit
    (let loop ((attempts 10))
      (if (and (> attempts 0) (process-running? pid))
          (begin
            (usleep 100000)  ; 100ms
            (loop (- attempts 1)))
          (begin
            ;; Clean up PID file
            (when (file-exists? (daemon-pid-path))
              (delete-file (daemon-pid-path)))
            `((stopped . #t)))))))

(define (daemon-restart)
  "Restart the xm daemon."
  (when (daemon-running?)
    (daemon-stop))
  (daemon-start))

;;; --------------------------------------------------------------------
;;; Daemon Loop (Placeholder)
;;; --------------------------------------------------------------------

(define (run-daemon-loop)
  "Main daemon loop - sets up Goblins actors and listens for connections.
   This is a placeholder that will be replaced with actual Goblins runtime."

  (format #t "xm daemon starting at ~a\n"
          (date->string (current-date) "~Y-~m-~d ~H:~M:~S"))

  ;; In production, this would:
  ;; 1. Initialize Goblins vat
  ;; 2. Spawn core actors (gatekeeper, cap-store, journal, etc.)
  ;; 3. Open Unix socket for local CLI communication
  ;; 4. Optionally start OCapN listeners

  ;; For now, just sleep and respond to signals
  (let loop ()
    (sleep 60)
    (loop)))

;;; --------------------------------------------------------------------
;;; Daemon Client
;;; --------------------------------------------------------------------

(define (ensure-daemon-running)
  "Ensure daemon is running, starting it if necessary."
  (unless (daemon-running?)
    (daemon-start)))

(define (daemon-connect)
  "Connect to the daemon via Unix socket.
   Returns a socket port or #f if connection fails."
  (catch #t
    (lambda ()
      (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
        (connect sock AF_UNIX (daemon-socket-path))
        sock))
    (lambda (key . args)
      #f)))

(define (daemon-send-command sock command)
  "Send a command to the daemon and receive response.
   COMMAND should be an alist that will be serialized as JSON."
  (let ((request (scm->json command)))
    ;; Send request
    (display request sock)
    (display "\n" sock)
    (force-output sock)
    ;; Read response
    (let ((response (read-line sock)))
      (if (eof-object? response)
          #f
          (json->scm response)))))

;;; --------------------------------------------------------------------
;;; Utility Functions
;;; --------------------------------------------------------------------

(define (ensure-directory path)
  "Create directory if it doesn't exist."
  (unless (file-exists? path)
    (mkdir path #o755)))

(define (redirect-port from to)
  "Redirect FROM port to TO port."
  ;; In production, use dup2 or similar
  #t)
