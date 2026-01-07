;;; test-graph-sharing.scm - Test cross-agent graph access via OCapN
;;;
;;; SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;
;;; This demonstrates:
;;; 1. Agent Alice creates a knowledge graph with data
;;; 2. Alice creates a read-only capability for her graph
;;; 3. Alice exports the capability as a sturdyref
;;; 4. Agent Bob connects and enlivens the sturdyref
;;; 5. Bob queries Alice's graph through the capability

(use-modules (fibers)
             (goblins)
             (goblins actor-lib methods)
             (goblins ocapn captp)
             (goblins ocapn ids)
             (goblins ocapn netlayer tcp-tls)
             (ice-9 binary-ports)
             (ice-9 format)
             (rnrs bytevectors)
             (xm store)
             (xm gatekeeper)
             (xm capability)
             (xm vocabulary))

(define (main)
  (format #t "=== Cross-Agent Graph Sharing Test ===\n\n")

  ;; Load keys for both agents
  (define alice-key
    (call-with-input-file "/tmp/xm-agent-alice/tls-key.pem" get-bytevector-all))
  (define alice-cert
    (call-with-input-file "/tmp/xm-agent-alice/tls-cert.pem" get-bytevector-all))
  (define bob-key
    (call-with-input-file "/tmp/xm-agent-bob/tls-key.pem" get-bytevector-all))
  (define bob-cert
    (call-with-input-file "/tmp/xm-agent-bob/tls-cert.pem" get-bytevector-all))

  (format #t "Keys loaded for Alice and Bob\n")

  ;; Run inside fibers for async networking
  (run-fibers
   (lambda ()
     ;; === ALICE: Create knowledge graph and share it ===
     (format #t "\n--- Setting up Agent Alice (port 9418) ---\n")

     (define alice-vat (spawn-vat))
     (define alice-store #f)
     (define alice-gatekeeper #f)
     (define alice-read-cap #f)
     (define alice-netlayer #f)
     (define alice-mycapn #f)
     (define alice-sturdyref #f)

     ;; Set up Alice's knowledge graph
     (call-with-vat alice-vat
       (lambda ()
         ;; Create in-memory store with some knowledge
         (set! alice-store (make-memory-store))
         (format #t "Alice: Created knowledge store\n")

         ;; Insert some knowledge about programming languages
         (define alice-graph "https://alice.example/knowledge")

         (store-load-graph alice-store
           "
           @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
           @prefix xm: <https://xm.dev/ns/v1#> .

           <https://alice.example/lisp> a xm:Language ;
               rdfs:label \"Lisp\" ;
               xm:creator \"John McCarthy\" ;
               xm:year 1958 .

           <https://alice.example/scheme> a xm:Language ;
               rdfs:label \"Scheme\" ;
               xm:creator \"Guy Steele\" ;
               xm:derivedFrom <https://alice.example/lisp> ;
               xm:year 1975 .

           <https://alice.example/guile> a xm:Language ;
               rdfs:label \"GNU Guile\" ;
               xm:derivedFrom <https://alice.example/scheme> ;
               xm:year 1993 .
           "
           #:graph alice-graph
           #:format "turtle")

         (format #t "Alice: Loaded knowledge about programming languages\n")
         (format #t "Alice: Store has ~a quads\n" (store-count alice-store))

         ;; Create gatekeeper actor
         (set! alice-gatekeeper (spawn ^graph-gatekeeper alice-store))
         (format #t "Alice: Graph gatekeeper created\n")

         ;; Create a read-only capability for the knowledge graph
         (set! alice-read-cap
               (spawn ^read-only-graph-facet
                      alice-gatekeeper
                      (list alice-graph)
                      #:label "alice-knowledge-readonly"))
         (format #t "Alice: Created read-only capability for knowledge graph\n")

         ;; Set up tcp-tls netlayer
         (set! alice-netlayer
               (spawn ^tcp-tls-netlayer "127.0.0.1"
                      #:port 9418
                      #:key alice-key
                      #:cert alice-cert))
         (format #t "Alice: tcp-tls netlayer listening on 127.0.0.1:9418\n")

         (set! alice-mycapn (spawn-mycapn alice-netlayer))
         (format #t "Alice: OCapN captp ready\n")

         ;; Export the read-only capability
         (set! alice-sturdyref (<- alice-mycapn 'register alice-read-cap 'tcp-tls))
         (format #t "Alice: Registering capability for export...\n")))

     ;; Wait for sturdyref and set up Bob
     (call-with-vat alice-vat
       (lambda ()
         (on alice-sturdyref
             (lambda (sref)
               (let ((uri (ocapn-id->string sref)))
                 (format #t "\nAlice: Capability exported!\n")
                 (format #t "Alice: Sturdyref URI:\n  ~a\n\n" uri)

                 ;; === BOB: Connect and query Alice's graph ===
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

                     ;; Enliven Alice's capability sturdyref
                     (format #t "Bob: Enlivening Alice's capability sturdyref...\n")
                     (define remote-cap-vow (<- bob-mycapn 'enliven sref))

                     (on remote-cap-vow
                         (lambda (remote-cap)
                           (format #t "Bob: Got live reference to Alice's graph capability!\n\n")

                           ;; First, get capability info
                           (format #t "Bob: Querying capability info...\n")
                           (define info-vow (<- remote-cap 'info))

                           (on info-vow
                               (lambda (info)
                                 (format #t "Bob: Capability info: ~s\n\n" info)

                                 ;; Now query Alice's graph with PREFIX declarations
                                 (format #t "Bob: Executing SPARQL query on Alice's graph...\n")
                                 (define query-vow
                                   (<- remote-cap 'query
                                       "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
                                        PREFIX xm: <https://xm.dev/ns/v1#>
                                        SELECT ?name ?creator ?year
                                        WHERE {
                                          ?lang a xm:Language ;
                                                rdfs:label ?name .
                                          OPTIONAL { ?lang xm:creator ?creator }
                                          OPTIONAL { ?lang xm:year ?year }
                                        }
                                        ORDER BY ?year"))

                                 (on query-vow
                                     (lambda (results)
                                       (format #t "\n=== SUCCESS ===\n")
                                       (format #t "Bob queried Alice's graph!\n\n")
                                       (format #t "Query results (programming languages):\n")
                                       (format #t "~a\n" results)
                                       (primitive-exit 0))
                                     #:catch
                                     (lambda (err)
                                       (format #t "Error executing query: ~a\n" err)
                                       (primitive-exit 1))))
                               #:catch
                               (lambda (err)
                                 (format #t "Error getting info: ~a\n" err)
                                 (primitive-exit 1))))
                         #:catch
                         (lambda (err)
                           (format #t "Error enlivening sturdyref: ~a\n" err)
                           (primitive-exit 1)))))))
             #:catch
             (lambda (err)
               (format #t "Error registering capability: ~a\n" err)
               (primitive-exit 1)))))

     ;; Keep fibers loop running
     (let loop ()
       (sleep 1)
       (loop)))
   #:parallelism 1
   #:hz 0))

(main)
