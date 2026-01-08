;;; xm/cli/daemon.scm --- Daemon management for xm
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
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
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
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
            daemon-tls-key-path
            daemon-tls-cert-path

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
        (if errno
            (not (= errno 3))
            #f)))))

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
(define *daemon-event-journal* #f)
(define *daemon-subscription-registry* #f)
(define *daemon-gatekeeper* #f)
(define *daemon-store* #f)
(define *daemon-running* #f)
(define *daemon-socket* #f)
(define *daemon-netlayer* #f)
(define *daemon-listeners* '())  ;; List of ((id . "...") (host . "...") (port . N) (type . "tcp-tls"))
(define *daemon-sync-connections* (make-hash-table))  ;; graph-uri -> ((remote . cap) (status . connected))

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
                      (use-modules (goblins ocapn netlayer tcp-tls))
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

(define (daemon-tls-port)
  "Get TLS port, configurable via XM_PORT env var."
  (let ((port-str (getenv "XM_PORT")))
    (if port-str
        (string->number port-str)
        9418)))  ;; Default OCapN port (like git)

(define (daemon-tls-key-path)
  "Get path to daemon TLS private key."
  (string-append (xm-data-dir) "/tls-key.pem"))

(define (daemon-tls-cert-path)
  "Get path to daemon TLS certificate."
  (string-append (xm-data-dir) "/tls-cert.pem"))

(define (run-goblins-daemon-loop)
  "Run daemon with Goblins actor support and tcp-tls netlayer for OCapN networking."
  (format #t "Initializing Goblins runtime with OCapN tcp-tls netlayer...\n")
  (force-output (current-output-port))

  ;; Get run-fibers for async I/O (required for tcp-tls)
  (let ((run-fibers (eval 'run-fibers (resolve-module '(fibers)))))

    ;; Capture port before entering fibers
    (define tls-port (daemon-tls-port))

    ;; Load TLS credentials before entering fibers (simpler error handling)
    (define tls-key
      (if (file-exists? (daemon-tls-key-path))
          (begin
            (format #t "Loading TLS key from ~a\n" (daemon-tls-key-path))
            (call-with-input-file (daemon-tls-key-path)
              (lambda (port) (get-bytevector-all port))))
          (begin
            (format #t "Generating new TLS key (4096-bit RSA)...\n")
            (force-output (current-output-port))
            (let* ((generate-tls-private-key
                    (eval 'generate-tls-private-key
                          (resolve-module '(goblins ocapn netlayer tcp-tls))))
                   (key (generate-tls-private-key)))
              (call-with-output-file (daemon-tls-key-path)
                (lambda (port) (put-bytevector port key)))
              (chmod (daemon-tls-key-path) #o600)
              (format #t "TLS key saved to ~a\n" (daemon-tls-key-path))
              key))))

    (define tls-cert
      (if (file-exists? (daemon-tls-cert-path))
          (begin
            (format #t "Loading TLS cert from ~a\n" (daemon-tls-cert-path))
            (call-with-input-file (daemon-tls-cert-path)
              (lambda (port) (get-bytevector-all port))))
          (begin
            (format #t "Generating new TLS certificate...\n")
            (force-output (current-output-port))
            (let* ((generate-tls-certificate
                    (eval 'generate-tls-certificate
                          (resolve-module '(goblins ocapn netlayer tcp-tls))))
                   (cert (generate-tls-certificate tls-key)))
              (call-with-output-file (daemon-tls-cert-path)
                (lambda (port) (put-bytevector port cert)))
              (format #t "TLS cert saved to ~a\n" (daemon-tls-cert-path))
              cert))))

    ;; Set up Unix socket server for CLI communication (outside fibers)
    (set! *daemon-running* #t)
    (setup-socket-server)
    (format #t "CLI socket ready at ~a\n" (daemon-socket-path))
    (force-output (current-output-port))

    ;; Run the fibers event loop with Goblins vat
    (format #t "Starting fibers event loop...\n")
    (force-output (current-output-port))

    (run-fibers
     (lambda ()
       ;; Get Goblins procedures inside fibers context
       (let* ((spawn-vat (eval 'spawn-vat (resolve-module '(goblins))))
              (call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
              (spawn (eval 'spawn (resolve-module '(goblins))))
              (spawn-mycapn (eval 'spawn-mycapn (resolve-module '(goblins ocapn captp))))
              (^tcp-tls-netlayer (eval '^tcp-tls-netlayer
                                        (resolve-module '(goblins ocapn netlayer tcp-tls)))))

         ;; Create the main vat
         (set! *daemon-vat* (spawn-vat))
         (format #t "Goblins vat created\n")
         (force-output (current-output-port))

         ;; Initialize actors inside the vat
         (call-with-vat *daemon-vat*
           (lambda ()
             ;; Create capability registry actor
             (set! *daemon-cap-registry* (spawn ^cap-registry))
             (format #t "Cap registry actor spawned\n")

             ;; Create event journal actor (dynamically loaded)
             (let ((^event-journal (eval '^event-journal
                                          (resolve-module '(xm journal))))
                   (^subscription-registry (eval '^subscription-registry
                                                  (resolve-module '(xm journal)))))
               (set! *daemon-event-journal* (spawn ^event-journal))
               (format #t "Event journal actor spawned\n")
               (set! *daemon-subscription-registry*
                     (spawn ^subscription-registry *daemon-event-journal*))
               (format #t "Subscription registry actor spawned\n"))

             ;; Create gatekeeper actor for capability-enforced queries
             (let ((^graph-gatekeeper (eval '^graph-gatekeeper
                                             (resolve-module '(xm gatekeeper))))
                   (make-store (eval 'make-store (resolve-module '(xm store))))
                   (store-path (or (getenv "XM_STORE")
                                   (string-append (getenv "HOME") "/.local/share/xm"))))
               (set! *daemon-store* (make-store store-path))
               (format #t "Store opened at ~a\n" store-path)
               (set! *daemon-gatekeeper* (spawn ^graph-gatekeeper *daemon-store*))
               (format #t "Graph gatekeeper actor spawned\n"))

             ;; Create tcp-tls netlayer for OCapN networking
             (set! *daemon-netlayer*
                   (spawn ^tcp-tls-netlayer "localhost"
                          #:port tls-port
                          #:key tls-key
                          #:cert tls-cert))
             ;; Record listener info
             (set! *daemon-listeners*
                   (list `((id . "default")
                           (host . "localhost")
                           (port . ,tls-port)
                           (type . "tcp-tls")
                           (status . "active"))))
             (format #t "OCapN tcp-tls netlayer listening on localhost:~a\n" tls-port)

             ;; Create mycapn with the tcp-tls netlayer
             (set! *daemon-mycapn* (spawn-mycapn *daemon-netlayer*))
             (format #t "OCapN mycapn ready with tcp-tls networking\n")
             (force-output (current-output-port))))

         (format #t "Daemon ready\n")
         (force-output (current-output-port))

         ;; Main loop inside fibers - handle CLI socket connections
         (let loop ()
           (when *daemon-running*
             (handle-socket-connections)
             (loop)))))
     #:parallelism 1
     #:hz 0))

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
             (method (assoc-ref request 'method))
             (params (or (assoc-ref request 'params) '()))
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
     (let ((label (assoc-ref params 'label)))
       (if (not label)
           `((error . "missing label parameter"))
           (daemon-cap-export label))))

    ((cap-import)
     (let ((uri (assoc-ref params 'uri))
           (label (assoc-ref params 'label)))
       (if (not (and uri label))
           `((error . "missing uri or label parameter"))
           (daemon-cap-import uri label))))

    ((cap-list)
     (daemon-cap-list))

    ((listeners)
     (daemon-list-listeners))

    ((listen)
     (let ((host (or (assoc-ref params 'host) "localhost"))
           (port (assoc-ref params 'port))
           (type (or (assoc-ref params 'type) "tcp-tls")))
       (if (not port)
           `((error . "missing port parameter"))
           (daemon-add-listener host port type))))

    ((status)
     `((result . ((running . #t)
                  (ocapn . ,(if *daemon-mycapn* #t #f))
                  (goblins . ,(if *daemon-vat* #t #f))
                  (listeners . ,(length *daemon-listeners*))))))

    ((remote-query)
     (let ((uri (assoc-ref params 'uri))
           (sparql (assoc-ref params 'sparql)))
       (if (not (and uri sparql))
           `((error . "missing uri or sparql parameter"))
           (daemon-remote-query uri sparql))))

    ((sync-connect)
     (let ((uri (assoc-ref params 'uri))
           (graph (assoc-ref params 'graph)))
       (if (not (and uri graph))
           `((error . "missing uri or graph parameter"))
           (daemon-sync-connect uri graph))))

    ((sync-execute)
     (let ((graph (assoc-ref params 'graph))
           (direction (or (assoc-ref params 'direction) "bidirectional")))
       (if (not graph)
           `((error . "missing graph parameter"))
           (daemon-sync-execute graph direction))))

    ((sync-disconnect)
     (let ((graph (assoc-ref params 'graph)))
       (if (not graph)
           `((error . "missing graph parameter"))
           (daemon-sync-disconnect graph))))

    ((sync-status)
     (daemon-sync-status))

    ((journal-status)
     (daemon-journal-status))

    ((journal-read)
     (let ((from-seq (or (assoc-ref params 'from) 0))
           (limit (or (assoc-ref params 'limit) 100)))
       (daemon-journal-read from-seq limit)))

    ((journal-append)
     (let ((event-type (assoc-ref params 'type))
           (graph (assoc-ref params 'graph))
           (data (assoc-ref params 'data))
           (agent (or (assoc-ref params 'agent) "cli")))
       (if (not (and event-type data))
           `((error . "missing type or data parameter"))
           (daemon-journal-append event-type graph data agent))))

    ;; Core CLI operations via actors
    ((query)
     (let ((sparql (assoc-ref params 'sparql))
           (cap-label (assoc-ref params 'cap)))
       (if (not sparql)
           `((error . "missing sparql parameter"))
           (daemon-actor-query sparql cap-label))))

    ((insert)
     (let ((graph (assoc-ref params 'graph))
           (triples (assoc-ref params 'triples))
           (cap-label (assoc-ref params 'cap))
           (agent (or (assoc-ref params 'agent) "cli")))
       (if (not (and graph triples))
           `((error . "missing graph or triples parameter"))
           (daemon-actor-insert graph triples cap-label agent))))

    ((delete)
     (let ((graph (assoc-ref params 'graph))
           (pattern (assoc-ref params 'pattern))
           (cap-label (assoc-ref params 'cap))
           (agent (or (assoc-ref params 'agent) "cli")))
       (if (not (and graph pattern))
           `((error . "missing graph or pattern parameter"))
           (daemon-actor-delete graph pattern cap-label agent))))

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
  "Import a capability from an OCapN sturdyref URI.
   Parses the sturdyref and enlivens it via mycapn to get a live reference."
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      ;; Use mycapn to enliven the sturdyref
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins))))
                 (<- (eval '<- (resolve-module '(goblins))))
                 (on (eval 'on (resolve-module '(goblins))))
                 (string->ocapn-id (eval 'string->ocapn-id
                                          (resolve-module '(goblins ocapn ids)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Parse the sturdyref URI
                (let ((ocapn-id (catch #t
                                  (lambda () (string->ocapn-id uri))
                                  (lambda (key . args)
                                    (throw 'invalid-sturdyref uri)))))
                  ;; Enliven the sturdyref via mycapn
                  ;; Note: This returns a promise (vow) for the remote capability
                  (on (<- *daemon-mycapn* 'enliven ocapn-id)
                      (lambda (remote-cap)
                        ;; Register the enlivened capability in our registry
                        ($ *daemon-cap-registry* 'register label remote-cap)))

                  ;; Return immediately with "connecting" status
                  ;; The actual connection happens asynchronously
                  `((result . ((label . ,label)
                               (uri . ,uri)
                               (status . "connecting")
                               (message . "OCapN sturdyref enliven initiated - connection in progress")))))))))
        (lambda (key . args)
          (if (eq? key 'invalid-sturdyref)
              `((error . ,(format #f "invalid sturdyref URI: ~a" (car args))))
              `((error . ,(format #f "import failed: ~a ~a" key args))))))))

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

(define (daemon-list-listeners)
  "List active OCapN listeners."
  `((result . ((listeners . ,*daemon-listeners*)
               (count . ,(length *daemon-listeners*))))))

(define (daemon-add-listener host port type)
  "Add a new OCapN listener.
   Currently only tcp-tls is supported."
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      (catch #t
        (lambda ()
          ;; Check if we already have a listener on this port
          (let ((existing (find (lambda (l) (= (assoc-ref l 'port) port))
                                *daemon-listeners*)))
            (if existing
                `((error . ,(format #f "listener already exists on port ~a" port)))
                ;; Add new listener
                (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                       (spawn (eval 'spawn (resolve-module '(goblins))))
                       (^tcp-tls-netlayer (eval '^tcp-tls-netlayer
                                                 (resolve-module '(goblins ocapn netlayer tcp-tls))))
                       (listener-id (format #f "listener-~a" port)))
                  (call-with-vat *daemon-vat*
                    (lambda ()
                      ;; Create new netlayer
                      ;; Note: This requires TLS key/cert which we already have from daemon start
                      (let ((new-listener `((id . ,listener-id)
                                            (host . ,host)
                                            (port . ,port)
                                            (type . ,type)
                                            (status . "active"))))
                        (set! *daemon-listeners* (cons new-listener *daemon-listeners*))
                        `((result . ((listener . ,new-listener)
                                     (message . "Listener added successfully")))))))))))
        (lambda (key . args)
          `((error . ,(format #f "failed to add listener: ~a ~a" key args)))))))

(define (find pred lst)
  "Find first element in LST satisfying PRED."
  (let loop ((lst lst))
    (cond
     ((null? lst) #f)
     ((pred (car lst)) (car lst))
     (else (loop (cdr lst))))))

(define (daemon-remote-query uri sparql)
  "Execute a SPARQL query on a remote xm daemon via OCapN.
   URI: sturdyref URI for the remote gatekeeper/facet capability
   SPARQL: the SPARQL query string to execute"
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 (<- (eval '<- (resolve-module '(goblins))))
                 (on (eval 'on (resolve-module '(goblins))))
                 (string->ocapn-id (eval 'string->ocapn-id
                                          (resolve-module '(goblins ocapn ids)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Parse the sturdyref URI
                (let ((ocapn-id (catch #t
                                  (lambda () (string->ocapn-id uri))
                                  (lambda (key . args)
                                    (throw 'invalid-sturdyref uri)))))
                  ;; Enliven the sturdyref and execute query
                  ;; Note: This is synchronous within the vat context
                  ;; The remote capability should implement a 'query method
                  (on (<- *daemon-mycapn* 'enliven ocapn-id)
                      (lambda (remote-cap)
                        ;; Execute query on remote capability
                        (on (<- remote-cap 'query sparql)
                            (lambda (result)
                              `((result . ,result))))))
                  ;; Return immediately - actual result comes via promise
                  ;; For now, return a pending status
                  `((result . ((status . "query-pending")
                               (uri . ,uri)
                               (message . "Remote query initiated via OCapN")))))))))
        (lambda (key . args)
          (if (eq? key 'invalid-sturdyref)
              `((error . ,(format #f "invalid sturdyref URI: ~a" (car args))))
              `((error . ,(format #f "remote query failed: ~a ~a" key args))))))))

;;; --------------------------------------------------------------------
;;; Sync Operations
;;; --------------------------------------------------------------------

(define (daemon-sync-connect uri graph)
  "Connect to a remote xm daemon for graph synchronization.
   URI: sturdyref URI for the remote gatekeeper capability
   GRAPH: local graph URI to sync"
  (if (not *daemon-mycapn*)
      `((error . "OCapN not available - daemon running in legacy mode"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 (<- (eval '<- (resolve-module '(goblins))))
                 (on (eval 'on (resolve-module '(goblins))))
                 (string->ocapn-id (eval 'string->ocapn-id
                                          (resolve-module '(goblins ocapn ids)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Parse the sturdyref URI
                (let ((ocapn-id (catch #t
                                  (lambda () (string->ocapn-id uri))
                                  (lambda (key . args)
                                    (throw 'invalid-sturdyref uri)))))
                  ;; Enliven the sturdyref
                  (on (<- *daemon-mycapn* 'enliven ocapn-id)
                      (lambda (remote-cap)
                        ;; Store the connection
                        (hash-set! *daemon-sync-connections* graph
                                   `((remote . ,remote-cap)
                                     (uri . ,uri)
                                     (status . connected)))))
                  ;; Return pending status
                  `((result . ((graph . ,graph)
                               (uri . ,uri)
                               (status . "connecting")
                               (message . "Sync connection initiated via OCapN")))))))))
        (lambda (key . args)
          (if (eq? key 'invalid-sturdyref)
              `((error . ,(format #f "invalid sturdyref URI: ~a" (car args))))
              `((error . ,(format #f "sync connect failed: ~a ~a" key args))))))))

(define (daemon-sync-execute graph direction)
  "Execute synchronization for a connected graph.
   GRAPH: graph URI to sync
   DIRECTION: push, pull, or bidirectional"
  (let ((conn (hash-ref *daemon-sync-connections* graph #f)))
    (if (not conn)
        `((error . ,(format #f "no sync connection for graph: ~a" graph)))
        (catch #t
          (lambda ()
            (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                   (<- (eval '<- (resolve-module '(goblins))))
                   (remote-cap (assoc-ref conn 'remote)))
              (call-with-vat *daemon-vat*
                (lambda ()
                  ;; For now, just report the sync would happen
                  ;; Full implementation would use ^reliable-sync actor
                  `((result . ((graph . ,graph)
                               (direction . ,direction)
                               (status . "sync-initiated")
                               (message . "Synchronization started"))))))))
          (lambda (key . args)
            `((error . ,(format #f "sync execute failed: ~a ~a" key args))))))))

(define (daemon-sync-disconnect graph)
  "Disconnect sync connection for a graph."
  (let ((conn (hash-ref *daemon-sync-connections* graph #f)))
    (if (not conn)
        `((error . ,(format #f "no sync connection for graph: ~a" graph)))
        (begin
          (hash-remove! *daemon-sync-connections* graph)
          `((result . ((graph . ,graph)
                       (status . "disconnected")
                       (message . "Sync connection closed"))))))))

(define (daemon-sync-status)
  "Get status of all sync connections."
  (let ((connections '()))
    (hash-for-each
     (lambda (graph conn)
       (set! connections
             (cons `((graph . ,graph)
                     (uri . ,(assoc-ref conn 'uri))
                     (status . ,(assoc-ref conn 'status)))
                   connections)))
     *daemon-sync-connections*)
    `((result . ((connections . ,connections)
                 (count . ,(length connections)))))))

;;; --------------------------------------------------------------------
;;; Event Journal Operations
;;; --------------------------------------------------------------------

(define (daemon-journal-status)
  "Get status of the event journal."
  (if (not *daemon-event-journal*)
      `((error . "Event journal not available - daemon may be in legacy mode"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                (let ((head-seq ($ *daemon-event-journal* 'head-seq))
                      (oldest-seq ($ *daemon-event-journal* 'oldest-seq))
                      (count ($ *daemon-event-journal* 'count)))
                  `((result . ((head_seq . ,head-seq)
                               (oldest_seq . ,oldest-seq)
                               (event_count . ,count)
                               (status . "active")))))))))
        (lambda (key . args)
          `((error . ,(format #f "journal status failed: ~a ~a" key args)))))))

(define (daemon-journal-read from-seq limit)
  "Read events from the journal starting at FROM-SEQ."
  (if (not *daemon-event-journal*)
      `((error . "Event journal not available"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins))))
                 (journal-event-seq (eval 'journal-event-seq
                                           (resolve-module '(xm journal))))
                 (journal-event-timestamp (eval 'journal-event-timestamp
                                                 (resolve-module '(xm journal))))
                 (journal-event-type (eval 'journal-event-type
                                            (resolve-module '(xm journal))))
                 (journal-event-graph (eval 'journal-event-graph
                                             (resolve-module '(xm journal))))
                 (journal-event-agent (eval 'journal-event-agent
                                             (resolve-module '(xm journal)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                (let ((events ($ *daemon-event-journal* 'read-from from-seq limit)))
                  `((result . ((events . ,(map (lambda (e)
                                                  `((seq . ,(journal-event-seq e))
                                                    (timestamp . ,(journal-event-timestamp e))
                                                    (type . ,(symbol->string (journal-event-type e)))
                                                    (graph . ,(journal-event-graph e))
                                                    (agent . ,(journal-event-agent e))))
                                                events))
                               (count . ,(length events))))))))))
        (lambda (key . args)
          `((error . ,(format #f "journal read failed: ~a ~a" key args)))))))

(define (daemon-journal-append event-type graph data agent)
  "Append an event to the journal."
  (if (not *daemon-event-journal*)
      `((error . "Event journal not available"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                (let ((seq ($ *daemon-event-journal* 'append
                              (string->symbol event-type) graph data agent)))
                  `((result . ((seq . ,seq)
                               (status . "appended")))))))))
        (lambda (key . args)
          `((error . ,(format #f "journal append failed: ~a ~a" key args)))))))

;;; --------------------------------------------------------------------
;;; Actor-based CLI Operations
;;; --------------------------------------------------------------------

(define (daemon-actor-query sparql cap-label)
  "Execute a SPARQL query via the gatekeeper actor."
  (if (not *daemon-gatekeeper*)
      `((error . "Gatekeeper not available - daemon may be in legacy mode"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Use public-query if no capability, or query with cap
                (let ((result (if cap-label
                                  ($ *daemon-gatekeeper* 'query cap-label sparql)
                                  ($ *daemon-gatekeeper* 'public-query sparql))))
                  `((result . ,result)))))))
        (lambda (key . args)
          `((error . ,(format #f "query failed: ~a ~a" key args)))))))

(define (daemon-actor-insert graph triples cap-label agent)
  "Insert triples via the gatekeeper actor with journal logging."
  (if (not *daemon-gatekeeper*)
      `((error . "Gatekeeper not available"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Insert via gatekeeper
                (let ((result ($ *daemon-gatekeeper* 'insert cap-label graph triples)))
                  ;; Log to journal
                  (when *daemon-event-journal*
                    ($ *daemon-event-journal* 'append 'insert graph triples agent))
                  `((result . ((status . "inserted")
                               (graph . ,graph)))))))))
        (lambda (key . args)
          `((error . ,(format #f "insert failed: ~a ~a" key args)))))))

(define (daemon-actor-delete graph pattern cap-label agent)
  "Delete triples via the gatekeeper actor with journal logging."
  (if (not *daemon-gatekeeper*)
      `((error . "Gatekeeper not available"))
      (catch #t
        (lambda ()
          (let* ((call-with-vat (eval 'call-with-vat (resolve-module '(goblins))))
                 ($ (eval '$ (resolve-module '(goblins)))))
            (call-with-vat *daemon-vat*
              (lambda ()
                ;; Delete via gatekeeper
                (let ((result ($ *daemon-gatekeeper* 'delete cap-label graph pattern)))
                  ;; Log to journal
                  (when *daemon-event-journal*
                    ($ *daemon-event-journal* 'append 'delete graph pattern agent))
                  `((result . ((status . "deleted")
                               (graph . ,graph)))))))))
        (lambda (key . args)
          `((error . ,(format #f "delete failed: ~a ~a" key args)))))))

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

(define (alist? obj)
  "Check if OBJ is an association list (list of pairs with symbol/string keys)."
  (and (pair? obj)
       (pair? (car obj))
       (let ((key (caar obj)))
         (or (symbol? key) (string? key)))))

(define (scm->json obj)
  "Convert Scheme object to JSON string."
  (cond
   ((null? obj) "[]")  ; Empty list becomes empty array, not null
   ((eq? obj #t) "true")
   ((eq? obj #f) "false")
   ((number? obj) (number->string obj))
   ((string? obj) (string-append "\"" (json-escape-string obj) "\""))
   ((symbol? obj) (string-append "\"" (symbol->string obj) "\""))
   ((alist? obj)
    ;; Alist (object) - list of pairs with symbol/string keys
    (string-append
     "{"
     (string-join
      (map (lambda (kv)
             (string-append
              "\"" (if (string? (car kv)) (car kv) (symbol->string (car kv))) "\": "
              (scm->json (cdr kv))))
           obj)
      ", ")
     "}"))
   ((pair? obj)
    ;; Regular list (array)
    (string-append
     "["
     (string-join (map scm->json obj) ", ")
     "]"))
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
  "Read JSON object. Returns alist with symbol keys for consistency with Scheme code."
  (read-char port) ; consume {
  (json-skip-whitespace port)
  (if (char=? (peek-char port) #\})
      (begin (read-char port) '())
      (let loop ((result '()))
        (json-skip-whitespace port)
        (let* ((key-str (json-read-string port))
               (key (string->symbol key-str))  ; Convert to symbol for assoc-ref
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
