;;; eval/locomo/ingest.scm --- LoCoMo dataset ingestion into xm
;;;
;;; Copyright (C) 2026 Digital Services Team
;;; SPDX-License-Identifier: Apache-2.0
;;;
;;; This module ingests LoCoMo conversations into the xm RDF store,
;;; creating nodes for speakers, sessions, utterances, events, and observations.

(define-module (eval locomo ingest)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (xm store)
  #:use-module (xm vocabulary)
  #:export (ingest-locomo-file
            ingest-conversation
            ingest-speaker
            ingest-session
            ingest-utterance
            ingest-event
            ingest-observation
            clear-locomo-graph))

;;; --------------------------------------------------------------------
;;; LoCoMo-specific vocabulary
;;; --------------------------------------------------------------------

;; Node types
(define locomo:Agent (string-append xm-ns "locomo/Agent"))
(define locomo:Session (string-append xm-ns "locomo/Session"))
(define locomo:Utterance (string-append xm-ns "locomo/Utterance"))
(define locomo:Event (string-append xm-ns "locomo/Event"))
(define locomo:Observation (string-append xm-ns "locomo/Observation"))
(define locomo:Conversation (string-append xm-ns "locomo/Conversation"))

;; Predicates
(define locomo:name (string-append xm-ns "locomo/name"))
(define locomo:text (string-append xm-ns "locomo/text"))
(define locomo:diaId (string-append xm-ns "locomo/diaId"))
(define locomo:date (string-append xm-ns "locomo/date"))
(define locomo:turnIndex (string-append xm-ns "locomo/turnIndex"))
(define locomo:sessionIndex (string-append xm-ns "locomo/sessionIndex"))
(define locomo:sampleId (string-append xm-ns "locomo/sampleId"))
(define locomo:evidenceRef (string-append xm-ns "locomo/evidenceRef"))

;; Relations
(define locomo:said (string-append xm-ns "locomo/said"))
(define locomo:contains (string-append xm-ns "locomo/contains"))
(define locomo:inSession (string-append xm-ns "locomo/inSession"))
(define locomo:inConversation (string-append xm-ns "locomo/inConversation"))
(define locomo:mentions (string-append xm-ns "locomo/mentions"))
(define locomo:experienced (string-append xm-ns "locomo/experienced"))
(define locomo:follows (string-append xm-ns "locomo/follows"))
(define locomo:hasParticipant (string-append xm-ns "locomo/hasParticipant"))
(define locomo:occursIn (string-append xm-ns "locomo/occursIn"))
(define locomo:supportedBy (string-append xm-ns "locomo/supportedBy"))

;;; --------------------------------------------------------------------
;;; URI generators for LoCoMo entities
;;; --------------------------------------------------------------------

(define (locomo-graph-uri conv-id)
  "Generate a named graph URI for a LoCoMo conversation."
  (string-append xm-ns "graph/locomo/" conv-id))

(define (locomo-conversation-uri conv-id)
  "Generate URI for a conversation."
  (string-append xm-ns "locomo/conversation/" conv-id))

(define (locomo-speaker-uri conv-id name)
  "Generate URI for a speaker in a conversation."
  (string-append xm-ns "locomo/agent/" conv-id "/" (sanitize-uri-component name)))

(define (locomo-session-uri conv-id session-idx)
  "Generate URI for a session."
  (string-append xm-ns "locomo/session/" conv-id "/" (number->string session-idx)))

(define (locomo-utterance-uri dia-id)
  "Generate URI for an utterance using its dia_id (e.g., D1:3)."
  (string-append xm-ns "locomo/utterance/" (sanitize-uri-component dia-id)))

(define (locomo-event-uri conv-id session-idx speaker event-idx)
  "Generate URI for an event."
  (string-append xm-ns "locomo/event/" conv-id "/"
                 (number->string session-idx) "/"
                 (sanitize-uri-component speaker) "/"
                 (number->string event-idx)))

(define (locomo-observation-uri conv-id session-idx speaker obs-idx)
  "Generate URI for an observation."
  (string-append xm-ns "locomo/observation/" conv-id "/"
                 (number->string session-idx) "/"
                 (sanitize-uri-component speaker) "/"
                 (number->string obs-idx)))

(define (sanitize-uri-component str)
  "Sanitize a string for use in a URI component."
  (string-map (lambda (c)
                (if (or (char-alphabetic? c)
                        (char-numeric? c)
                        (char=? c #\-)
                        (char=? c #\_))
                    c
                    #\_))
              (string-downcase str)))

;;; --------------------------------------------------------------------
;;; JSON Access Helpers
;;; --------------------------------------------------------------------

(define (json-ref obj key)
  "Get value from JSON alist by key."
  (assoc-ref obj key))

(define (json-ref* obj . keys)
  "Nested JSON access."
  (let loop ((obj obj) (keys keys))
    (if (or (null? keys) (not obj))
        obj
        (loop (json-ref obj (car keys)) (cdr keys)))))

;;; --------------------------------------------------------------------
;;; Main Ingestion Entry Point
;;; --------------------------------------------------------------------

(define* (ingest-locomo-file store filepath #:key (verbose #f))
  "Ingest entire LoCoMo dataset from JSON file.
   Returns list of conversation IDs ingested."
  (let* ((json-str (call-with-input-file filepath
                     (lambda (port)
                       (get-string-all port))))
         (conversations (json-string->scm json-str)))
    (when verbose
      (format #t "Loaded ~a conversations from ~a~%"
              (length conversations) filepath))
    (map (lambda (conv)
           (ingest-conversation store conv #:verbose verbose))
         conversations)))

(define* (ingest-conversation store conv #:key (verbose #f))
  "Ingest a single LoCoMo conversation into the store.
   Returns the conversation ID."
  (let* ((sample-id (json-ref conv "sample_id"))
         (graph-uri (locomo-graph-uri sample-id))
         (conv-uri (locomo-conversation-uri sample-id))
         (conversation-data (json-ref conv "conversation"))
         (speaker-a (json-ref conversation-data "speaker_a"))
         (speaker-b (json-ref conversation-data "speaker_b")))

    (when verbose
      (format #t "Ingesting conversation ~a (~a, ~a)~%"
              sample-id speaker-a speaker-b))

    ;; Create conversation node
    (store-insert-quad store conv-uri rdf:type locomo:Conversation #:graph graph-uri)
    (store-insert-quad store conv-uri locomo:sampleId sample-id #:graph graph-uri)

    ;; Ingest speakers
    (let ((speaker-a-uri (ingest-speaker store graph-uri sample-id speaker-a))
          (speaker-b-uri (ingest-speaker store graph-uri sample-id speaker-b)))

      ;; Link speakers to conversation
      (store-insert-quad store conv-uri locomo:hasParticipant speaker-a-uri #:graph graph-uri)
      (store-insert-quad store conv-uri locomo:hasParticipant speaker-b-uri #:graph graph-uri)

      ;; Ingest sessions (session_1 through session_35 potentially)
      (let loop ((session-idx 1)
                 (prev-utterance-uri #f))
        (let ((session-key (string-append "session_" (number->string session-idx)))
              (date-key (string-append "session_" (number->string session-idx) "_date_time")))
          (when (json-ref conversation-data session-key)
            (let ((session-date (json-ref conversation-data date-key))
                  (dialog (json-ref conversation-data session-key)))
              (let ((last-utt-uri (ingest-session store graph-uri sample-id
                                                   session-idx session-date dialog
                                                   speaker-a-uri speaker-b-uri
                                                   speaker-a speaker-b
                                                   conv-uri prev-utterance-uri)))
                (loop (+ session-idx 1) last-utt-uri))))))

      ;; Ingest event summaries
      (let ((event-summary (json-ref conv "event_summary")))
        (when event-summary
          (ingest-event-summaries store graph-uri sample-id event-summary
                                   speaker-a speaker-a-uri
                                   speaker-b speaker-b-uri)))

      ;; Ingest observations
      (let ((observations (json-ref conv "observation")))
        (when observations
          (ingest-observations store graph-uri sample-id observations
                               speaker-a speaker-a-uri
                               speaker-b speaker-b-uri))))

    sample-id))

;;; --------------------------------------------------------------------
;;; Speaker Ingestion
;;; --------------------------------------------------------------------

(define (ingest-speaker store graph-uri conv-id name)
  "Create a speaker/agent node. Returns the speaker URI."
  (let ((uri (locomo-speaker-uri conv-id name)))
    (store-insert-quad store uri rdf:type locomo:Agent #:graph graph-uri)
    (store-insert-quad store uri locomo:name name #:graph graph-uri)
    uri))

;;; --------------------------------------------------------------------
;;; Session Ingestion
;;; --------------------------------------------------------------------

(define (ingest-session store graph-uri conv-id session-idx date dialog
                        speaker-a-uri speaker-b-uri speaker-a speaker-b
                        conv-uri prev-utterance-uri)
  "Ingest a conversation session with all its utterances.
   Returns the URI of the last utterance in the session."
  (let ((session-uri (locomo-session-uri conv-id session-idx)))

    ;; Create session node
    (store-insert-quad store session-uri rdf:type locomo:Session #:graph graph-uri)
    (store-insert-quad store session-uri locomo:sessionIndex
                       (number->string session-idx) #:graph graph-uri)
    (when date
      (store-insert-quad store session-uri locomo:date date #:graph graph-uri))
    (store-insert-quad store session-uri locomo:inConversation conv-uri #:graph graph-uri)

    ;; Ingest each utterance in the dialog
    (let loop ((turns dialog)
               (turn-idx 0)
               (prev-utt prev-utterance-uri))
      (if (null? turns)
          prev-utt  ; Return last utterance URI
          (let* ((turn (car turns))
                 (speaker-name (json-ref turn "speaker"))
                 (dia-id (json-ref turn "dia_id"))
                 (text (json-ref turn "text"))
                 (speaker-uri (if (string=? speaker-name speaker-a)
                                  speaker-a-uri
                                  speaker-b-uri))
                 (utt-uri (ingest-utterance store graph-uri session-uri
                                            speaker-uri dia-id text turn-idx
                                            prev-utt)))
            (loop (cdr turns) (+ turn-idx 1) utt-uri))))))

;;; --------------------------------------------------------------------
;;; Utterance Ingestion
;;; --------------------------------------------------------------------

(define (ingest-utterance store graph-uri session-uri speaker-uri
                          dia-id text turn-idx prev-utterance-uri)
  "Create an utterance node with all links. Returns the utterance URI."
  (let ((utt-uri (locomo-utterance-uri dia-id)))

    ;; Create utterance node
    (store-insert-quad store utt-uri rdf:type locomo:Utterance #:graph graph-uri)
    (store-insert-quad store utt-uri locomo:diaId dia-id #:graph graph-uri)
    (store-insert-quad store utt-uri locomo:text text #:graph graph-uri)
    (store-insert-quad store utt-uri locomo:turnIndex
                       (number->string turn-idx) #:graph graph-uri)

    ;; Link to speaker (speaker said this utterance)
    (store-insert-quad store speaker-uri locomo:said utt-uri #:graph graph-uri)

    ;; Link to session (session contains this utterance)
    (store-insert-quad store session-uri locomo:contains utt-uri #:graph graph-uri)
    (store-insert-quad store utt-uri locomo:inSession session-uri #:graph graph-uri)

    ;; Link to previous utterance (dialog flow)
    (when prev-utterance-uri
      (store-insert-quad store utt-uri locomo:follows prev-utterance-uri #:graph graph-uri))

    utt-uri))

;;; --------------------------------------------------------------------
;;; Event Summary Ingestion
;;; --------------------------------------------------------------------

(define (ingest-event-summaries store graph-uri conv-id event-summary
                                 speaker-a speaker-a-uri
                                 speaker-b speaker-b-uri)
  "Ingest all event summaries for a conversation."
  (for-each
   (lambda (key-value)
     (let* ((key (car key-value))  ; e.g., "events_session_1"
            (events (cdr key-value))
            (session-idx (extract-session-number key)))
       (when session-idx
         (let ((session-uri (locomo-session-uri conv-id session-idx))
               (event-date (json-ref events "date")))
           ;; Ingest events for speaker_a
           (let ((speaker-a-events (json-ref events speaker-a)))
             (when (and speaker-a-events (list? speaker-a-events))
               (let loop ((evts speaker-a-events) (idx 0))
                 (unless (null? evts)
                   (ingest-event store graph-uri conv-id session-idx
                                 speaker-a speaker-a-uri (car evts) idx
                                 session-uri event-date)
                   (loop (cdr evts) (+ idx 1))))))
           ;; Ingest events for speaker_b
           (let ((speaker-b-events (json-ref events speaker-b)))
             (when (and speaker-b-events (list? speaker-b-events))
               (let loop ((evts speaker-b-events) (idx 0))
                 (unless (null? evts)
                   (ingest-event store graph-uri conv-id session-idx
                                 speaker-b speaker-b-uri (car evts) idx
                                 session-uri event-date)
                   (loop (cdr evts) (+ idx 1))))))))))
   event-summary))

(define (ingest-event store graph-uri conv-id session-idx speaker speaker-uri
                      description idx session-uri event-date)
  "Create an event node."
  (let ((event-uri (locomo-event-uri conv-id session-idx speaker idx)))
    (store-insert-quad store event-uri rdf:type locomo:Event #:graph graph-uri)
    (store-insert-quad store event-uri locomo:text description #:graph graph-uri)
    (when event-date
      (store-insert-quad store event-uri locomo:date event-date #:graph graph-uri))
    ;; Link to speaker
    (store-insert-quad store speaker-uri locomo:experienced event-uri #:graph graph-uri)
    ;; Link to session
    (store-insert-quad store event-uri locomo:occursIn session-uri #:graph graph-uri)
    event-uri))

;;; --------------------------------------------------------------------
;;; Observation Ingestion
;;; --------------------------------------------------------------------

(define (ingest-observations store graph-uri conv-id observations
                             speaker-a speaker-a-uri
                             speaker-b speaker-b-uri)
  "Ingest all observations for a conversation."
  (for-each
   (lambda (key-value)
     (let* ((key (car key-value))  ; e.g., "session_1_observation"
            (obs-data (cdr key-value))
            (session-idx (extract-session-number key)))
       (when session-idx
         (let ((session-uri (locomo-session-uri conv-id session-idx)))
           ;; Ingest observations for speaker_a
           (let ((speaker-a-obs (json-ref obs-data speaker-a)))
             (when (and speaker-a-obs (list? speaker-a-obs))
               (let loop ((obs-list speaker-a-obs) (idx 0))
                 (unless (null? obs-list)
                   (let ((obs-item (car obs-list)))
                     (when (and (list? obs-item) (>= (length obs-item) 2))
                       (ingest-observation store graph-uri conv-id session-idx
                                           speaker-a speaker-a-uri
                                           (list-ref obs-item 0)  ; text
                                           (list-ref obs-item 1)  ; evidence ref
                                           idx session-uri)))
                   (loop (cdr obs-list) (+ idx 1))))))
           ;; Ingest observations for speaker_b
           (let ((speaker-b-obs (json-ref obs-data speaker-b)))
             (when (and speaker-b-obs (list? speaker-b-obs))
               (let loop ((obs-list speaker-b-obs) (idx 0))
                 (unless (null? obs-list)
                   (let ((obs-item (car obs-list)))
                     (when (and (list? obs-item) (>= (length obs-item) 2))
                       (ingest-observation store graph-uri conv-id session-idx
                                           speaker-b speaker-b-uri
                                           (list-ref obs-item 0)
                                           (list-ref obs-item 1)
                                           idx session-uri)))
                   (loop (cdr obs-list) (+ idx 1))))))))))
   observations))

(define (ingest-observation store graph-uri conv-id session-idx speaker speaker-uri
                            text evidence-ref idx session-uri)
  "Create an observation node with evidence link."
  (let ((obs-uri (locomo-observation-uri conv-id session-idx speaker idx)))
    (store-insert-quad store obs-uri rdf:type locomo:Observation #:graph graph-uri)
    (store-insert-quad store obs-uri locomo:text text #:graph graph-uri)
    (store-insert-quad store obs-uri locomo:evidenceRef evidence-ref #:graph graph-uri)
    ;; Link to the utterance that supports this observation
    (let ((utt-uri (locomo-utterance-uri evidence-ref)))
      (store-insert-quad store obs-uri locomo:supportedBy utt-uri #:graph graph-uri))
    ;; Link to speaker
    (store-insert-quad store speaker-uri locomo:experienced obs-uri #:graph graph-uri)
    ;; Link to session
    (store-insert-quad store obs-uri locomo:occursIn session-uri #:graph graph-uri)
    obs-uri))

;;; --------------------------------------------------------------------
;;; Helper Functions
;;; --------------------------------------------------------------------

(define (extract-session-number key)
  "Extract session number from keys like 'session_1_observation' or 'events_session_1'.
   Returns #f if no valid number found."
  (let ((parts (string-split key #\_)))
    (let loop ((parts parts))
      (if (null? parts)
          #f
          (let ((n (string->number (car parts))))
            (if n n (loop (cdr parts))))))))

(define (get-string-all port)
  "Read all remaining characters from PORT as a string."
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define (clear-locomo-graph store conv-id)
  "Clear all data for a specific LoCoMo conversation."
  (let ((graph-uri (locomo-graph-uri conv-id)))
    (store-update store
                  (format #f "DROP GRAPH <~a>" graph-uri))))
