;;; xm/cli/keys.scm --- Key management for xm agent identity
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module manages the TLS keys that form the persistent identity
;;; of an xm agent. The SHA256 hash of the certificate is used in OCapN
;;; sturdyrefs to identify this agent to peers.

(define-module (xm cli keys)
  #:use-module (ice-9 format)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs bytevectors)
  #:use-module (xm cli output)
  #:export (keys-command
            keys-info
            keys-generate
            keys-fingerprint
            keys-path
            keys-import
            keys-export
            get-agent-fingerprint))

;;; --------------------------------------------------------------------
;;; Path Configuration
;;; --------------------------------------------------------------------

(define (xm-data-dir)
  "Get xm data directory."
  (or (getenv "XM_STORE")
      (string-append (or (getenv "XDG_DATA_HOME")
                         (string-append (getenv "HOME") "/.local/share"))
                     "/xm")))

(define (tls-key-path)
  "Get path to TLS private key."
  (string-append (xm-data-dir) "/tls-key.pem"))

(define (tls-cert-path)
  "Get path to TLS certificate."
  (string-append (xm-data-dir) "/tls-cert.pem"))

;;; --------------------------------------------------------------------
;;; Key Operations
;;; --------------------------------------------------------------------

(define (ensure-goblins-loaded)
  "Load Goblins tcp-tls module, return #t on success."
  (catch #t
    (lambda ()
      (eval '(use-modules (goblins ocapn netlayer tcp-tls)
                          (goblins utils crypto)
                          (goblins utils base32))
            (interaction-environment))
      #t)
    (lambda (key . args)
      (format (current-error-port)
              "Error: Goblins not available. Install guile-goblins.\n")
      #f)))

(define (compute-fingerprint cert-bytevector)
  "Compute the base32-encoded SHA256 fingerprint of a certificate."
  (let ((sha256d (eval 'sha256d (resolve-module '(goblins utils crypto))))
        (base32-encode (eval 'base32-encode (resolve-module '(goblins utils base32)))))
    (base32-encode (sha256d cert-bytevector))))

(define (get-agent-fingerprint)
  "Get the fingerprint of this agent's certificate, or #f if no keys exist."
  (if (file-exists? (tls-cert-path))
      (begin
        (ensure-goblins-loaded)
        (let ((cert (call-with-input-file (tls-cert-path)
                      (lambda (port) (get-bytevector-all port)))))
          (compute-fingerprint cert)))
      #f))

(define (generate-keys)
  "Generate new TLS key and certificate. Returns (key . cert) bytevectors."
  (unless (ensure-goblins-loaded)
    (error "Cannot generate keys without Goblins"))

  (let ((generate-tls-private-key
         (eval 'generate-tls-private-key
               (resolve-module '(goblins ocapn netlayer tcp-tls))))
        (generate-tls-certificate
         (eval 'generate-tls-certificate
               (resolve-module '(goblins ocapn netlayer tcp-tls)))))

    (format #t "Generating 4096-bit RSA private key...\n")
    (let* ((key (generate-tls-private-key))
           (_ (format #t "Generating self-signed certificate...\n"))
           (cert (generate-tls-certificate key)))
      (cons key cert))))

(define (save-keys key cert)
  "Save key and cert to disk with appropriate permissions."
  ;; Ensure directory exists
  (let ((dir (xm-data-dir)))
    (unless (file-exists? dir)
      (mkdir dir #o700)))

  ;; Save private key (restricted permissions)
  (call-with-output-file (tls-key-path)
    (lambda (port) (put-bytevector port key)))
  (chmod (tls-key-path) #o600)

  ;; Save certificate (readable)
  (call-with-output-file (tls-cert-path)
    (lambda (port) (put-bytevector port cert)))
  (chmod (tls-cert-path) #o644))

;;; --------------------------------------------------------------------
;;; CLI Commands
;;; --------------------------------------------------------------------

(define (keys-info args)
  "Show information about agent keys."
  (let ((key-exists (file-exists? (tls-key-path)))
        (cert-exists (file-exists? (tls-cert-path))))

    (if (not (or key-exists cert-exists))
        (begin
          (format #t "No keys found.\n")
          (format #t "Run 'xm keys generate' to create agent identity.\n"))
        (begin
          (format #t "Agent Identity\n")
          (format #t "==============\n\n")

          (when cert-exists
            (ensure-goblins-loaded)
            (let* ((cert (call-with-input-file (tls-cert-path)
                           (lambda (port) (get-bytevector-all port))))
                   (fingerprint (compute-fingerprint cert)))
              (format #t "Fingerprint: ~a\n" fingerprint)
              (format #t "Cert size:   ~a bytes\n" (bytevector-length cert))))

          (format #t "\nPaths:\n")
          (format #t "  Private key:  ~a ~a\n"
                  (tls-key-path)
                  (if key-exists "" "(missing)"))
          (format #t "  Certificate:  ~a ~a\n"
                  (tls-cert-path)
                  (if cert-exists "" "(missing)"))

          (when (and key-exists (not cert-exists))
            (format #t "\nWarning: Private key exists but certificate is missing.\n")
            (format #t "Run 'xm keys generate' to regenerate both.\n"))))))

(define (keys-generate args)
  "Generate new agent keys."
  (let ((force (member "--force" args)))

    ;; Check for existing keys
    (when (and (file-exists? (tls-key-path)) (not force))
      (format #t "Keys already exist at:\n")
      (format #t "  ~a\n" (tls-key-path))
      (format #t "  ~a\n" (tls-cert-path))
      (format #t "\nUse --force to regenerate (this changes agent identity!).\n")
      (exit 1))

    (when (and (file-exists? (tls-key-path)) force)
      (format #t "Warning: Regenerating keys will change agent identity.\n")
      (format #t "Existing sturdyrefs will no longer work.\n\n"))

    ;; Generate new keys
    (let* ((keys (generate-keys))
           (key (car keys))
           (cert (cdr keys)))

      ;; Save to disk
      (save-keys key cert)

      ;; Show result
      (let ((fingerprint (compute-fingerprint cert)))
        (format #t "\nAgent identity created.\n\n")
        (format #t "Fingerprint: ~a\n" fingerprint)
        (format #t "\nFiles saved:\n")
        (format #t "  ~a\n" (tls-key-path))
        (format #t "  ~a\n" (tls-cert-path))))))

(define (keys-fingerprint args)
  "Show just the agent fingerprint."
  (let ((fingerprint (get-agent-fingerprint)))
    (if fingerprint
        (display fingerprint)
        (begin
          (format (current-error-port) "No keys found. Run 'xm keys generate' first.\n")
          (exit 1)))
    (newline)))

(define (keys-path args)
  "Show paths to key files."
  (let ((what (if (pair? args) (car args) "all")))
    (cond
     ((string=? what "key") (display (tls-key-path)))
     ((string=? what "cert") (display (tls-cert-path)))
     (else
      (format #t "key:  ~a\n" (tls-key-path))
      (format #t "cert: ~a\n" (tls-cert-path))))
    (newline)))

(define (keys-export args)
  "Export agent keys to a directory or tarball."
  (unless (file-exists? (tls-key-path))
    (format (current-error-port) "No keys to export. Run 'xm keys generate' first.\n")
    (exit 1))

  (let ((output-path (if (pair? args) (car args) "xm-identity")))
    (ensure-goblins-loaded)
    (let* ((cert (call-with-input-file (tls-cert-path)
                   (lambda (port) (get-bytevector-all port))))
           (fingerprint (compute-fingerprint cert)))

      ;; Create output directory
      (let ((key-out (string-append output-path ".key.pem"))
            (cert-out (string-append output-path ".cert.pem")))

        ;; Copy key (preserve permissions)
        (let ((key-data (call-with-input-file (tls-key-path)
                          (lambda (port) (get-bytevector-all port)))))
          (call-with-output-file key-out
            (lambda (port) (put-bytevector port key-data)))
          (chmod key-out #o600))

        ;; Copy cert
        (call-with-output-file cert-out
          (lambda (port) (put-bytevector port cert)))

        (format #t "Exported agent identity:\n")
        (format #t "  Fingerprint: ~a\n" fingerprint)
        (format #t "  Private key: ~a\n" key-out)
        (format #t "  Certificate: ~a\n" cert-out)
        (format #t "\nKeep the private key secure!\n")))))

(define (keys-import args)
  "Import agent keys from exported files."
  (when (null? args)
    (format (current-error-port) "Usage: xm keys import <path-prefix>\n")
    (format (current-error-port) "  Imports <path-prefix>.key.pem and <path-prefix>.cert.pem\n")
    (exit 1))

  (let* ((input-path (car args))
         (force (member "--force" args))
         (key-in (string-append input-path ".key.pem"))
         (cert-in (string-append input-path ".cert.pem")))

    ;; Check input files exist
    (unless (file-exists? key-in)
      (format (current-error-port) "Key file not found: ~a\n" key-in)
      (exit 1))
    (unless (file-exists? cert-in)
      (format (current-error-port) "Cert file not found: ~a\n" cert-in)
      (exit 1))

    ;; Check for existing keys
    (when (and (file-exists? (tls-key-path)) (not force))
      (format #t "Keys already exist. Use --force to overwrite.\n")
      (format #t "Warning: This will change the agent's identity!\n")
      (exit 1))

    ;; Load and validate the imported cert
    (ensure-goblins-loaded)
    (let* ((key-data (call-with-input-file key-in
                       (lambda (port) (get-bytevector-all port))))
           (cert-data (call-with-input-file cert-in
                        (lambda (port) (get-bytevector-all port))))
           (fingerprint (compute-fingerprint cert-data)))

      ;; Save to xm data directory
      (save-keys key-data cert-data)

      (format #t "Imported agent identity:\n")
      (format #t "  Fingerprint: ~a\n" fingerprint)
      (format #t "  Saved to:    ~a\n" (xm-data-dir))
      (format #t "\nThis agent now has the imported identity.\n"))))

(define (keys-command args)
  "Main entry point for 'xm keys' command."
  (let ((subcommand (if (pair? args) (car args) "info"))
        (rest (if (pair? args) (cdr args) '())))
    (cond
     ((string=? subcommand "info") (keys-info rest))
     ((string=? subcommand "generate") (keys-generate rest))
     ((string=? subcommand "fingerprint") (keys-fingerprint rest))
     ((string=? subcommand "path") (keys-path rest))
     ((string=? subcommand "export") (keys-export rest))
     ((string=? subcommand "import") (keys-import rest))
     ((string=? subcommand "help")
      (format #t "Usage: xm keys <command>\n\n")
      (format #t "Manage agent identity keys for OCapN networking.\n\n")
      (format #t "Commands:\n")
      (format #t "  info         Show agent identity (fingerprint, paths)\n")
      (format #t "  generate     Generate new agent keys (--force to regenerate)\n")
      (format #t "  fingerprint  Print just the fingerprint (for scripts)\n")
      (format #t "  path [key|cert]  Show paths to key files\n")
      (format #t "  export [PREFIX]  Export keys to PREFIX.key.pem and PREFIX.cert.pem\n")
      (format #t "  import PREFIX    Import keys from PREFIX.key.pem and PREFIX.cert.pem\n")
      (format #t "\nThe fingerprint (SHA256 of cert) identifies this agent in OCapN sturdyrefs.\n"))
     (else
      (format (current-error-port) "Unknown keys command: ~a\n" subcommand)
      (format (current-error-port) "Run 'xm keys help' for usage.\n")
      (exit 1)))))
