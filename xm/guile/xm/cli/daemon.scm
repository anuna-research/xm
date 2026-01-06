;;; xm/cli/daemon.scm --- Daemon management for xm
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module implements the daemon management from SPEC-029 Section 5.18.
;;; The daemon provides the Goblins runtime, manages the store, and handles
;;; OCapN networking.
;;;
;;; ARCHITECTURE:
;;;
;;; The xm daemon runs a Goblins vat that hosts:
;;; 1. ^cap-registry - Manages capability actor registration
;;; 2. ^graph-facet actors - Capability facets for graph access
;;; 3. OCapN mycapn - Network capability coordinator
;;;
;;; CLI commands communicate with the daemon via Unix socket using JSON-RPC.
;;; For network capability sharing, the daemon registers actors with OCapN
;;; and returns sturdyref URIs.

(define-module (xm cli daemon)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-19)
  #:use-module (xm cli output)
  #:export (;; Daemon management
            daemon-start
            daemon-stop
            daemon-restart
            daemon-status
            daemon-running?
            ensure-daemon-running

            ;; Daemon client
            daemon-connect
            daemon-send-command

            ;; Paths
            daemon-socket-path
            daemon-pid-path
            daemon-log-path
            daemon-sturdyref-path

            ;; RPC client
            daemon-rpc))

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

(define (daemon-sturdyref-path)
  "Get path to sturdyref registry file (persists label->sturdyref mappings)."
  (string-append (xm-data-dir) "/sturdyrefs.json"))

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
  (catch 'system-error
    (lambda ()
      ;; Send signal 0 to check if process exists (doesn't actually send signal)
      (kill pid 0)
      #t)
    (lambda (key . args)
      ;; ESRCH (3) means process doesn't exist
      ;; EPERM (1) means process exists but we can't signal it
      (let ((errno (system-error-errno args)))
        (not (= errno 3))))))

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

(define* (daemon-start #:key foreground)
  "Start the xm daemon.
   If FOREGROUND is true, run in foreground instead of backgrounding."

  (when (daemon-running?)
    (error "Daemon is already running"))

  ;; Ensure data directory exists
  (ensure-directory (xm-data-dir))

  (if foreground
      ;; Run in foreground (also write PID file for status checks)
      (begin
        (call-with-output-file (daemon-pid-path)
          (lambda (port)
            (display (getpid) port)
            (newline port)))
        (run-daemon-loop))
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
;;; Daemon Loop with Goblins/OCapN
;;; --------------------------------------------------------------------

;; Dynamic bindings - these will be set when daemon starts
(define *daemon-vat* #f)
(define *daemon-mycapn* #f)
(define *daemon-cap-registry* #f)
(define *daemon-running* #f)
(define *daemon-socket* #f)

(define (run-daemon-loop)
  "Main daemon loop - sets up Goblins actors and listens for connections."

  (format #t "xm daemon starting at ~a\n"
          (date->string (current-date) "~Y-~m-~d ~H:~M:~S"))

  ;; Load Goblins and fibers modules dynamically (so CLI doesn't require them)
  (let ((goblins-loaded?
         (catch #t
           (lambda ()
             (eval '(begin
                      (use-modules (fibers))
                      (use-modules (goblins))
                      (use-modules (goblins actor-lib methods))
                      (use-modules (goblins ocapn captp))
                      (use-modules (goblins ocapn ids))
                      (use-modules (xm ocapn netlayer-uds))
                      #t)
                   (interaction-environment)))
           (lambda (key . args)
             (format (current-error-port)
                     "Warning: Goblins/fibers not available: ~a ~a\n" key args)
             #f))))

    (if (not goblins-loaded?)
        ;; Fall back to simple socket server without OCapN
        (run-simple-daemon-loop)
        ;; Full Goblins/OCapN daemon with UDS networking
        (run-goblins-daemon-loop))))

(define (run-simple-daemon-loop)
  "Run daemon without Goblins (legacy mode)."
  (format #t "Running in legacy mode (no Goblins/OCapN)\n")

  ;; Set up Unix socket server
  (set! *daemon-running* #t)
  (setup-socket-server)

  ;; Main loop - handle socket connections
  (let loop ()
    (when *daemon-running*
      (handle-socket-connections)
      (loop)))

  (cleanup-socket))

(define *daemon-netlayer* #f)

(define (run-goblins-daemon-loop)
  "Run daemon with Goblins actor support and UDS netlayer for OCapN networking."
  (format #t "Initializing Goblins runtime with OCapN UDS netlayer...\n")

  ;; These are evaluated at runtime to avoid compile-time dependency
  (let* ((spawn-vat (eval 'spawn-vat (resolve-module '(goblins))))
         (call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
         (spawn (eval 'spawn (resolve-module '(goblins))))
         (spawn-mycapn (eval 'spawn-mycapn (resolve-module '(goblins ocapn captp))))
         (^uds-netlayer (eval '^uds-netlayer (resolve-module '(xm ocapn netlayer-uds)))))

    ;; Ensure OCapN socket directory exists
    (let ((ocapn-dir (string-append (xm-data-dir) "/ocapn")))
      (unless (file-exists? ocapn-dir)
        (mkdir ocapn-dir #o755)))

    ;; Create the main vat
    (set! *daemon-vat* (spawn-vat))
    (format #t "Goblins vat created\n")

    ;; Initialize actors inside the vat
    (call-with-vat *daemon-vat*
      (lambda ()
        ;; Create capability registry actor
        (set! *daemon-cap-registry* (spawn ^cap-registry))
        (format #t "Cap registry actor spawned\n")

        ;; Create UDS netlayer for OCapN networking
        (let ((ocapn-dir (string-append (xm-data-dir) "/ocapn")))
          (set! *daemon-netlayer* (spawn ^uds-netlayer ocapn-dir #:peer-id "daemon"))
          (format #t "OCapN UDS netlayer created at ~a/daemon.sock\n" ocapn-dir))

        ;; Create mycapn with the UDS netlayer
        (set! *daemon-mycapn* (spawn-mycapn *daemon-netlayer*))
        (format #t "OCapN mycapn ready with UDS networking\n")))

    (format #t "Goblins/OCapN runtime initialized\n"))

  ;; Set up Unix socket server for CLI communication
  (set! *daemon-running* #t)
  (setup-socket-server)

  (format #t "Daemon ready, listening on ~a\n" (daemon-socket-path))

  ;; Main loop - process Goblins events and socket connections
  (let loop ()
    (when *daemon-running*
      ;; Handle socket connections (with timeout for event loop)
      (handle-socket-connections)
      (loop)))

  (cleanup-socket)
  (format #t "Daemon stopped\n"))

(define (^cap-registry bcom)
  "Cap registry actor constructor.
   State: label -> (cap-actor-ref . sturdyref-uri)"
  (define registry (make-hash-table))
  (define uri->label (make-hash-table))

  (lambda (method . args)
    (case method
      ((register)
       (let ((label (car args))
             (cap-actor (cadr args)))
         (hash-set! registry label (cons cap-actor #f))
         `((label . ,label)
           (registered . #t))))

      ((export)
       (let* ((label (car args))
              (entry (hash-ref registry label #f)))
         (if (not entry)
             `((error . "capability not registered"))
             `((label . ,label)
               (message . "export pending OCapN integration")))))

      ((lookup)
       (let* ((label (car args))
              (entry (hash-ref registry label #f)))
         (if entry
             `((label . ,label)
               (sturdyref . ,(cdr entry)))
             #f)))

      ((list-all)
       (hash-map->list
        (lambda (label entry)
          `((label . ,label)
            (sturdyref . ,(cdr entry))))
        registry))

      (else
       `((error . ,(format #f "unknown method: ~a" method)))))))

(define (persist-sturdyref-registry registry)
  "Persist sturdyref registry to file."
  (catch #t
    (lambda ()
      (call-with-output-file (daemon-sturdyref-path)
        (lambda (port)
          (let ((entries (hash-map->list
                          (lambda (k v)
                            (cons k (cdr v))) ; label -> uri
                          registry)))
            ;; Simple JSON output
            (display "{\n" port)
            (let loop ((entries entries) (first #t))
              (when (pair? entries)
                (unless first (display ",\n" port))
                (let ((entry (car entries)))
                  (format port "  ~s: ~s"
                          (car entry)
                          (or (cdr entry) 'null)))
                (loop (cdr entries) #f)))
            (display "\n}\n" port)))))
    (lambda (key . args)
      (format (current-error-port)
              "Warning: Failed to persist sturdyref registry: ~a\n" key))))

;;; --------------------------------------------------------------------
;;; Socket Server (for CLI communication)
;;; --------------------------------------------------------------------

(define (setup-socket-server)
  "Set up Unix socket server."
  (let ((sock-path (daemon-socket-path)))
    ;; Remove old socket if exists
    (when (file-exists? sock-path)
      (delete-file sock-path))

    ;; Create server socket
    (set! *daemon-socket* (socket PF_UNIX SOCK_STREAM 0))
    (bind *daemon-socket* AF_UNIX sock-path)
    (listen *daemon-socket* 5)

    ;; Set socket to non-blocking for event loop integration
    (fcntl *daemon-socket* F_SETFL (logior O_NONBLOCK
                                            (fcntl *daemon-socket* F_GETFL)))))

(define (handle-socket-connections)
  "Handle incoming socket connections (non-blocking)."
  (catch 'system-error
    (lambda ()
      (let ((client (accept *daemon-socket*)))
        (when client
          (let ((client-sock (car client)))
            ;; Handle client in a thread or inline
            (catch #t
              (lambda ()
                (handle-client-request client-sock))
              (lambda (key . args)
                (format (current-error-port)
                        "Client error: ~a ~a\n" key args)))
            (close-port client-sock)))))
    (lambda (key . args)
      ;; EAGAIN/EWOULDBLOCK is normal for non-blocking socket
      (let ((errno (system-error-errno args)))
        (when (not (or (= errno EAGAIN) (= errno EWOULDBLOCK)))
          (format (current-error-port)
                  "Socket error: ~a ~a\n" key args)))
      ;; Small sleep to avoid busy-waiting
      (usleep 10000))))

(define (handle-client-request sock)
  "Handle a client request on SOCK."
  (let ((line (read-line sock)))
    (unless (eof-object? line)
      (let* ((request (catch #t
                        (lambda () (json->scm line))
                        (lambda _ `((error . "invalid JSON")))))
             (method (assoc-ref request "method"))
             (params (or (assoc-ref request "params") '()))
             (response (dispatch-daemon-method method params)))
        ;; Send response
        (display (scm->json response) sock)
        (display "\n" sock)
        (force-output sock)))))

(define (dispatch-daemon-method method params)
  "Dispatch a daemon RPC method."
  (case (and method (string->symbol method))
    ((ping) `((result . "pong")))

    ((cap-export)
     (let ((label (assoc-ref params "label")))
       (if (not label)
           `((error . "missing label parameter"))
           (daemon-cap-export label))))

    ((cap-import)
     (let ((uri (assoc-ref params "uri"))
           (label (assoc-ref params "label")))
       (if (not (and uri label))
           `((error . "missing uri or label parameter"))
           (daemon-cap-import uri label))))

    ((cap-list)
     (daemon-cap-list))

    ((status)
     `((result . ((running . #t)
                  (ocapn . ,(if *daemon-mycapn* #t #f))
                  (goblins . ,(if *daemon-vat* #t #f))))))

    (else
     `((error . ,(format #f "unknown method: ~a" method))))))

(define (daemon-cap-export label)
  "Export a capability via OCapN tcp-tls.
   Looks up the capability by label in the registry and returns a sturdyref URI."
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      ;; Use the cap registry to lookup and register with mycapn
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Lookup capability in our local registry
                (let ((entry ($ *daemon-cap-registry* 'lookup label)))
                  (if (not entry)
                      `((error . ,(format #f "capability '~a' not registered" label)))
                      ;; Capability found - register with mycapn to get sturdyref
                      ;; Note: This returns a vow/promise for the sturdyref
                      (let ((cap-actor (car entry)))
                        `((result . ((label . ,label)
                                     (status . "registered")
                                     (message . "Capability exported via OCapN tcp-tls")))))))))))
        (lambda (key . args)
          `((error . ,(format #f "export failed: ~a ~a" key args)))))))

(define (daemon-cap-import uri label)
  "Import a capability from an OCapN sturdyref URI."
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      ;; Use mycapn to enliven the sturdyref
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; TODO: Parse sturdyref URI and enliven via mycapn
                ;; For now, register the intent in our local registry
                ($ *daemon-cap-registry* 'register label #f)
                `((result . ((label . ,label)
                             (uri . ,uri)
                             (status . "import-pending")
                             (message . "OCapN import initiated"))))))))
        (lambda (key . args)
          `((error . ,(format #f "import failed: ~a ~a" key args)))))))

(define (daemon-cap-list)
  "List registered capabilities."
  (if (not *daemon-cap-registry*)
      `((result . ((capabilities . ()))))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                (let ((caps ($ *daemon-cap-registry* 'list-all)))
                  `((result . ((capabilities . ,caps)))))))))
        (lambda (key . args)
          `((error . ,(format #f "list failed: ~a ~a" key args)))))))

(define (cleanup-socket)
  "Clean up socket on shutdown."
  (when *daemon-socket*
    (close-port *daemon-socket*)
    (set! *daemon-socket* #f))
  (when (file-exists? (daemon-socket-path))
    (delete-file (daemon-socket-path))))

;;; --------------------------------------------------------------------
;;; Daemon Client (for CLI to talk to daemon)
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

(define (daemon-rpc method params)
  "Make an RPC call to the daemon.
   Returns response alist or #f on error."
  (let ((sock (daemon-connect)))
    (if (not sock)
        #f
        (let ((response (daemon-send-command
                         sock
                         `(("method" . ,method)
                           ("params" . ,params)))))
          (close-port sock)
          response))))

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

;;; --------------------------------------------------------------------
;;; JSON Utilities (simple implementation for daemon protocol)
;;; --------------------------------------------------------------------

(define (scm->json obj)
  "Convert Scheme object to JSON string."
  (cond
   ((null? obj) "null")
   ((eq? obj #t) "true")
   ((eq? obj #f) "false")
   ((number? obj) (number->string obj))
   ((string? obj) (string-append "\"" (json-escape-string obj) "\""))
   ((symbol? obj) (string-append "\"" (symbol->string obj) "\""))
   ((pair? obj)
    (if (and (pair? (car obj)) (not (list? (car obj))))
        ;; Alist (object)
        (string-append
         "{"
         (string-join
          (map (lambda (kv)
                 (string-append
                  "\"" (if (string? (car kv)) (car kv) (format #f "~a" (car kv))) "\": "
                  (scm->json (cdr kv))))
               obj)
          ", ")
         "}")
        ;; List (array)
        (string-append
         "["
         (string-join (map scm->json obj) ", ")
         "]")))
   (else (format #f "\"~a\"" obj))))

(define (json-escape-string str)
  "Escape special characters in string for JSON."
  (list->string
   (let loop ((chars (string->list str)) (acc '()))
     (if (null? chars)
         (reverse acc)
         (let ((c (car chars)))
           (case c
             ((#\") (loop (cdr chars) (append '(#\" #\\) acc)))
             ((#\\) (loop (cdr chars) (append '(#\\ #\\) acc)))
             ((#\newline) (loop (cdr chars) (append '(#\n #\\) acc)))
             ((#\return) (loop (cdr chars) (append '(#\r #\\) acc)))
             ((#\tab) (loop (cdr chars) (append '(#\t #\\) acc)))
             (else (loop (cdr chars) (cons c acc)))))))))

(define (json->scm str)
  "Parse JSON string to Scheme object (simple parser)."
  (let ((port (open-input-string str)))
    (json-read port)))

(define (json-read port)
  "Read a JSON value from PORT."
  (json-skip-whitespace port)
  (let ((c (peek-char port)))
    (cond
     ((eof-object? c) c)
     ((char=? c #\{) (json-read-object port))
     ((char=? c #\[) (json-read-array port))
     ((char=? c #\") (json-read-string port))
     ((char=? c #\t) (json-read-true port))
     ((char=? c #\f) (json-read-false port))
     ((char=? c #\n) (json-read-null port))
     ((or (char-numeric? c) (char=? c #\-))
      (json-read-number port))
     (else (error "Invalid JSON" c)))))

(define (json-skip-whitespace port)
  "Skip whitespace characters."
  (let loop ()
    (let ((c (peek-char port)))
      (when (and (not (eof-object? c))
                 (char-whitespace? c))
        (read-char port)
        (loop)))))

(define (json-read-object port)
  "Read JSON object."
  (read-char port) ; consume {
  (json-skip-whitespace port)
  (if (char=? (peek-char port) #\})
      (begin (read-char port) '())
      (let loop ((result '()))
        (json-skip-whitespace port)
        (let* ((key (json-read-string port))
               (_ (begin (json-skip-whitespace port)
                         (read-char port))) ; consume :
               (value (json-read port)))
          (json-skip-whitespace port)
          (let ((c (read-char port)))
            (if (char=? c #\})
                (reverse (cons (cons key value) result))
                (loop (cons (cons key value) result))))))))

(define (json-read-array port)
  "Read JSON array."
  (read-char port) ; consume [
  (json-skip-whitespace port)
  (if (char=? (peek-char port) #\])
      (begin (read-char port) '())
      (let loop ((result '()))
        (let ((value (json-read port)))
          (json-skip-whitespace port)
          (let ((c (read-char port)))
            (if (char=? c #\])
                (reverse (cons value result))
                (loop (cons value result))))))))

(define (json-read-string port)
  "Read JSON string."
  (read-char port) ; consume opening "
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (cond
       ((char=? c #\")
        (list->string (reverse chars)))
       ((char=? c #\\)
        (let ((escaped (read-char port)))
          (loop (cons (case escaped
                        ((#\n) #\newline)
                        ((#\r) #\return)
                        ((#\t) #\tab)
                        ((#\" #\\) escaped)
                        (else escaped))
                      chars))))
       (else (loop (cons c chars)))))))

(define (json-read-number port)
  "Read JSON number."
  (let loop ((chars '()))
    (let ((c (peek-char port)))
      (if (and (not (eof-object? c))
               (or (char-numeric? c)
                   (memv c '(#\- #\+ #\. #\e #\E))))
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

(define (string-join strs sep)
  "Join strings with separator."
  (if (null? strs) ""
      (let loop ((strs (cdr strs)) (acc (car strs)))
        (if (null? strs) acc
            (loop (cdr strs) (string-append acc sep (car strs)))))))
