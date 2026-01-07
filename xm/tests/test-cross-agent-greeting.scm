;;; test-two-agents.scm - Test OCapN tcp-tls communication between two agents
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This demonstrates:
;;; 1. Agent Alice creates a greeter capability
;;; 2. Alice exports the capability as a sturdyref
;;; 3. Agent Bob connects and enlivens the sturdyref
;;; 4. Bob invokes the capability and gets a response

(use-modules (fibers)
             (goblins)
             (goblins actor-lib methods)
             (goblins ocapn captp)
             (goblins ocapn ids)
             (goblins ocapn netlayer tcp-tls)
             (ice-9 binary-ports)
             (ice-9 format)
             (rnrs bytevectors))

;;; A simple greeter actor that returns a personalized greeting
(define (^greeter bcom name)
  (methods
   [(greet who)
    (format #f "Hello ~a! I am ~a." who name)]
   [(whoami)
    name]))

(define (main)
  (format #t "=== Two-Agent OCapN tcp-tls Test ===\n\n")

  ;; Load or generate keys for Alice
  (define alice-key-path "/tmp/xm-agent-alice/tls-key.pem")
  (define alice-cert-path "/tmp/xm-agent-alice/tls-cert.pem")

  (define alice-key
    (if (file-exists? alice-key-path)
        (call-with-input-file alice-key-path get-bytevector-all)
        (let ((key (generate-tls-private-key)))
          (call-with-output-file alice-key-path
            (lambda (port) (put-bytevector port key)))
          key)))

  (define alice-cert
    (if (file-exists? alice-cert-path)
        (call-with-input-file alice-cert-path get-bytevector-all)
        (let ((cert (generate-tls-certificate alice-key)))
          (call-with-output-file alice-cert-path
            (lambda (port) (put-bytevector port cert)))
          cert)))

  ;; Load or generate keys for Bob
  (define bob-key-path "/tmp/xm-agent-bob/tls-key.pem")
  (define bob-cert-path "/tmp/xm-agent-bob/tls-cert.pem")

  (define bob-key
    (if (file-exists? bob-key-path)
        (call-with-input-file bob-key-path get-bytevector-all)
        (let ((key (generate-tls-private-key)))
          (call-with-output-file bob-key-path
            (lambda (port) (put-bytevector port key)))
          key)))

  (define bob-cert
    (if (file-exists? bob-cert-path)
        (call-with-input-file bob-cert-path get-bytevector-all)
        (let ((cert (generate-tls-certificate bob-key)))
          (call-with-output-file bob-cert-path
            (lambda (port) (put-bytevector port cert)))
          cert)))

  (format #t "Keys loaded for Alice and Bob\n")

  ;; Run inside fibers for async networking
  (run-fibers
   (lambda ()
     ;; === ALICE: Server agent on port 9418 ===
     (format #t "\n--- Setting up Agent Alice (port 9418) ---\n")

     (define alice-vat (spawn-vat))
     (define alice-greeter #f)
     (define alice-netlayer #f)
     (define alice-mycapn #f)
     (define alice-sturdyref #f)

     ;; Create Alice's greeter actor and netlayer
     (call-with-vat alice-vat
       (lambda ()
         (set! alice-greeter (spawn ^greeter "Alice"))
         (format #t "Alice: Created greeter actor\n")

         (set! alice-netlayer
               (spawn ^tcp-tls-netlayer "127.0.0.1"
                      #:port 9418
                      #:key alice-key
                      #:cert alice-cert))
         (format #t "Alice: tcp-tls netlayer listening on 127.0.0.1:9418\n")

         (set! alice-mycapn (spawn-mycapn alice-netlayer))
         (format #t "Alice: OCapN captp ready\n")

         ;; Register the greeter to get a sturdyref
         (set! alice-sturdyref (<- alice-mycapn 'register alice-greeter 'tcp-tls))
         (format #t "Alice: Registered greeter, sturdyref pending...\n")))

     ;; Wait for registration to complete
     (call-with-vat alice-vat
       (lambda ()
         (on alice-sturdyref
             (lambda (sref)
               (let ((uri (ocapn-id->string sref)))
                 (format #t "\nAlice: Greeter exported!\n")
                 (format #t "Alice: Sturdyref URI:\n  ~a\n\n" uri)

                 ;; === BOB: Client agent on port 9419 ===
                 (format #t "--- Setting up Agent Bob (port 9419) ---\n")

                 (define bob-vat (spawn-vat))

                 (call-with-vat bob-vat
                   (lambda ()
                     (define bob-netlayer
                       (spawn ^tcp-tls-netlayer "127.0.0.1"
                              #:port 9419
                              #:key bob-key
                              #:cert bob-cert))
                     (format #t "Bob: tcp-tls netlayer listening on 127.0.0.1:9419\n")

                     (define bob-mycapn (spawn-mycapn bob-netlayer))
                     (format #t "Bob: OCapN captp ready\n")

                     ;; Enliven Alice's sturdyref to get a live reference
                     (format #t "Bob: Enlivening Alice's sturdyref...\n")
                     (define remote-greeter-vow (<- bob-mycapn 'enliven sref))

                     (on remote-greeter-vow
                         (lambda (remote-greeter)
                           (format #t "Bob: Got live reference to Alice's greeter!\n")

                           ;; Invoke the remote capability
                           (format #t "Bob: Calling (greet \"Bob\")...\n")
                           (define greeting-vow (<- remote-greeter 'greet "Bob"))

                           (on greeting-vow
                               (lambda (greeting)
                                 (format #t "\n=== SUCCESS ===\n")
                                 (format #t "Bob received greeting: ~s\n" greeting)
                                 (format #t "\nCross-agent OCapN tcp-tls communication works!\n")
                                 ;; Exit after success
                                 (primitive-exit 0))
                               #:catch
                               (lambda (err)
                                 (format #t "Error getting greeting: ~a\n" err)
                                 (primitive-exit 1))))
                         #:catch
                         (lambda (err)
                           (format #t "Error enlivening sturdyref: ~a\n" err)
                           (primitive-exit 1)))))))
             #:catch
             (lambda (err)
               (format #t "Error registering greeter: ~a\n" err)
               (primitive-exit 1)))))

     ;; Keep the fibers loop running
     (let loop ()
       (sleep 1)
       (loop)))
   #:parallelism 1
   #:hz 0))

(main)
