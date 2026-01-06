;;; xm/ocapn/netlayer-uds.scm --- Unix Domain Socket netlayer for OCapN
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; macOS-compatible Unix Domain Socket netlayer for OCapN.
;;;
;;; This is a patched version of testuds that works on macOS by avoiding
;;; the SOCK_NONBLOCK flag in accept() which isn't supported on macOS.
;;; Instead, we set O_NONBLOCK on the accepted socket using fcntl().

(define-module (xm ocapn netlayer-uds)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins ocapn netlayer base-port)
  #:use-module (goblins ocapn ids)
  #:use-module (goblins utils random-name)
  #:use-module (ice-9 match)
  #:export (^uds-netlayer
            make-uds-server-socket
            make-uds-client-socket))

;;; --------------------------------------------------------------------
;;; Socket utilities (macOS compatible)
;;; --------------------------------------------------------------------

(define* (make-uds-server-socket path #:optional (listen-backlog 128))
  "Create a Unix domain socket server at PATH.
   Works on both Linux and macOS."
  (when (file-exists? path)
    (delete-file path))
  (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
    (setsockopt sock SOL_SOCKET SO_REUSEADDR 1)
    (fcntl sock F_SETFD FD_CLOEXEC)
    (bind sock AF_UNIX path)
    ;; Set server socket to non-blocking
    (fcntl sock F_SETFL (logior O_NONBLOCK (fcntl sock F_GETFL)))
    ;; Ignore SIGPIPE (broken pipe)
    (sigaction SIGPIPE SIG_IGN)
    (listen sock listen-backlog)
    sock))

(define (make-uds-client-socket path)
  "Connect to a Unix domain socket at PATH.
   Works on both Linux and macOS."
  (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
    (connect sock AF_UNIX path)
    ;; Set to non-blocking after connect
    (fcntl sock F_SETFL (logior O_NONBLOCK (fcntl sock F_GETFL)))
    sock))

(define (accept-nonblocking server-sock)
  "Accept a connection on SERVER-SOCK and set the client to non-blocking.
   This is macOS-compatible - we don't pass flags to accept().
   Instead we set O_NONBLOCK on the accepted socket using fcntl()."
  (match (accept server-sock)
    ((client . addr)
     ;; Set client socket to non-blocking (macOS compatible)
     (fcntl client F_SETFL (logior O_NONBLOCK (fcntl client F_GETFL)))
     (setvbuf client 'block 1024)
     client)))

;;; --------------------------------------------------------------------
;;; UDS Netlayer Actor
;;; --------------------------------------------------------------------

(define* (^uds-netlayer bcom netlayers-dir
                        #:key (peer-id (random-name 32)))
  "Unix Domain Socket netlayer for OCapN.

   NETLAYERS-DIR is the directory where socket files are created.
   PEER-ID is our unique identifier (defaults to random 32-char string).

   Socket files are created at: NETLAYERS-DIR/PEER-ID.sock"

  (define our-location
    (make-ocapn-peer 'uds peer-id '()))

  (define (sock-filename-for-id id)
    (string-append netlayers-dir "/" id ".sock"))

  (define our-sock-filename
    (sock-filename-for-id peer-id))

  ;; Create our server socket
  (define our-server-sock
    (make-uds-server-socket our-sock-filename))

  (define (incoming-accept)
    "Accept incoming connections (returns a vow that resolves to a port)."
    ;; Use spawn-fibrous-vow to do the accept in a fiber
    (spawn-fibrous-vow
     (lambda ()
       (accept-nonblocking our-server-sock))))

  (define (outgoing-connect-location location)
    "Connect to a remote peer (returns a vow that resolves to a port)."
    (unless (eq? (ocapn-peer-transport location) 'uds)
      (error "Wrong netlayer! Expected uds" location))
    (spawn-fibrous-vow
     (lambda ()
       (make-uds-client-socket
        (sock-filename-for-id (ocapn-peer-designator location))))))

  ;; Use the base-port netlayer with our accept/connect implementations
  (^base-port-netlayer bcom our-location
                       incoming-accept outgoing-connect-location))
