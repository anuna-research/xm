# Evaluating xm with LoCoMo

Empirical validation of xm as a long-term memory system using the LoCoMo benchmark.

## Overview

[LoCoMo](https://snap-research.github.io/locomo/) (Long-term Conversational Memory) is a benchmark from SNAP Research for evaluating how well LLMs utilize information from extended conversational histories. It provides a rigorous test of memory capabilities over 300+ turn conversations spanning months of interactions.

**Thesis:** xm's linked-data approach (RDF triples, bidirectional links, SPARQL queries) provides a more structured memory substrate than flat retrieval, potentially improving performance on long-term conversational memory tasks—particularly multi-hop reasoning and temporal queries.

## LoCoMo Benchmark

### Dataset Characteristics

| Property | Value |
|----------|-------|
| Conversations | 10 extended dialogues |
| Average turns | ~300 per conversation |
| Average tokens | ~9,000 per conversation |
| Sessions | Up to 35 per conversation |
| Annotations | QA pairs, event graphs, evidence links |

### Evaluation Tasks

1. **Question Answering** — Five reasoning categories:
   - Single-hop: Direct fact retrieval
   - Multi-hop: Reasoning across multiple facts
   - Temporal: Time-based reasoning
   - Commonsense: World knowledge integration
   - Adversarial: Questions with no answer in context

2. **Event Summarization** — Extract causal/temporal event graphs per speaker

3. **Multimodal Dialog Generation** — Generate contextually consistent responses

### Baseline Performance

LoCoMo reports that RAG and long-context LLMs improve QA by 22-66% over naive approaches but remain 56% below human performance. This gap motivates exploring structured memory approaches like xm.

## Mapping LoCoMo to xm

### Node Types

```
xm:agent      — Conversation participants (speakers)
xm:session    — Conversation sessions with temporal bounds
xm:utterance  — Individual dialog turns
xm:event      — Significant life events extracted from dialogue
xm:topic      — Recurring themes or entities mentioned
```

### Link Predicates

```
xm:said              — agent → utterance
xm:contains          — session → utterance
xm:mentions          — utterance → topic
xm:caused_by         — event → event (causal chain)
xm:occurred_before   — event → event (temporal ordering)
xm:experienced       — agent → event
xm:follows           — utterance → utterance (dialog flow)
```

### Ingestion Schema

```
LoCoMo Element          xm Representation
─────────────────────────────────────────────────────────────
Speaker                 xm node create -t agent \
                          -p name="Alice" \
                          -p persona="..."

Session                 xm node create -t session \
                          -p date="2024-03-15" \
                          -p session_id=5

Dialog turn             xm node create -t utterance \
                          -p text="I got the job!" \
                          -p timestamp="2024-03-15T14:30:00" \
                          -p turn_id=142

Event                   xm node create -t event \
                          -p description="Started new job" \
                          -p date="2024-03-15"

Causal relation         xm link create <event:job-offer> \
                          xm:caused_by <event:interview>

Speaker attribution     xm link create <agent:alice> \
                          xm:said <utterance:142>
```

## Experimental Conditions

### Retrieval Methods

| Condition | Description | xm Commands |
|-----------|-------------|-------------|
| **baseline-raw** | BM25/embedding over raw dialog text | None (control) |
| **baseline-obs** | RAG over extracted observations | None (LoCoMo's method) |
| **xm-sparql** | SPARQL queries for relevant triples | `xm query sparql` |
| **xm-backlinks** | Traverse backlinks from question entities | `xm query backlinks` |
| **xm-path** | Path queries for multi-hop reasoning | `xm query path` |
| **xm-hybrid** | SPARQL + embedding rerank | Combined |

### Query Strategies by Task

**Single-hop QA:**
```sparql
# "Where does Alice work?"
SELECT ?value WHERE {
  ?agent a xm:agent ; xm:name "Alice" .
  ?agent xm:experienced ?event .
  ?event xm:type "employment" ; xm:location ?value .
}
```

**Multi-hop QA:**
```bash
# "Why did Alice move to Seattle?"
# 1. Find Alice's move event
# 2. Traverse xm:caused_by links
xm query path <agent:alice> xm:caused_by* <event:move-seattle>
```

**Temporal QA:**
```sparql
# "What happened before Alice's promotion?"
SELECT ?event ?date WHERE {
  ?promo a xm:event ; xm:description "promotion" ; xm:date ?promo_date .
  ?event xm:occurred_before ?promo ; xm:date ?date .
} ORDER BY DESC(?date) LIMIT 5
```

**Event Summarization:**
```bash
# Extract event graph for speaker
xm query sparql "
  SELECT ?e1 ?rel ?e2 WHERE {
    ?agent xm:name 'Alice' ; xm:experienced ?e1 .
    ?e1 ?rel ?e2 .
    FILTER(?rel IN (xm:caused_by, xm:occurred_before))
  }
"
```

## Implementation

### Directory Structure

```
xm/eval/locomo/
├── README.md
├── ingest.scm          # LoCoMo → xm ingestion
├── retrieve.scm        # Query strategies
├── evaluate.scm        # Scoring against ground truth
├── conditions/
│   ├── baseline-raw.scm
│   ├── baseline-obs.scm
│   ├── xm-sparql.scm
│   ├── xm-backlinks.scm
│   ├── xm-path.scm
│   └── xm-hybrid.scm
├── data/
│   └── locomo10.json   # LoCoMo dataset
└── results/
    └── .gitkeep
```

### Ingestion Pipeline

```scheme
;; ingest.scm — Parse LoCoMo JSON and populate xm store

(define (ingest-conversation conv)
  "Ingest a single LoCoMo conversation into xm."
  (let* ((conv-id (assoc-ref conv "conversation_id"))
         (sessions (assoc-ref conv "sessions")))

    ;; Create agent nodes for speakers
    (for-each ingest-speaker (assoc-ref conv "speakers"))

    ;; Create session and utterance nodes
    (for-each (lambda (session)
                (ingest-session conv-id session))
              sessions)

    ;; Create event nodes and causal links
    (for-each (lambda (speaker)
                (ingest-events conv-id speaker))
              (assoc-ref conv "speakers"))))

(define (ingest-utterance session-id turn)
  "Create utterance node with links."
  (let* ((turn-id (assoc-ref turn "turn_id"))
         (speaker (assoc-ref turn "speaker"))
         (text (assoc-ref turn "text"))
         (node-id (xm-node-create
                    #:type "utterance"
                    #:props `((text . ,text)
                              (turn_id . ,turn-id)))))
    ;; Link to speaker
    (xm-link-create (speaker->node-id speaker) "xm:said" node-id)
    ;; Link to session
    (xm-link-create (session->node-id session-id) "xm:contains" node-id)
    node-id))
```

### Retrieval Interface

```scheme
;; retrieve.scm — Query xm for relevant context

(define (retrieve-context question strategy)
  "Retrieve context from xm using specified strategy."
  (case strategy
    ((sparql)    (retrieve-sparql question))
    ((backlinks) (retrieve-backlinks question))
    ((path)      (retrieve-path question))
    ((hybrid)    (retrieve-hybrid question))
    (else        (error "Unknown strategy" strategy))))

(define (retrieve-backlinks question)
  "Extract entities and traverse backlinks."
  (let* ((entities (extract-entities question))  ; NER or LLM extraction
         (node-ids (map entity->node-id entities))
         (subgraph (apply append
                          (map (lambda (nid)
                                 (xm-query-backlinks nid #:depth 2))
                               node-ids))))
    (format-as-context subgraph)))

(define (retrieve-path question)
  "Find paths between question entities."
  (let* ((entities (extract-entities question))
         (node-ids (map entity->node-id entities)))
    (if (>= (length node-ids) 2)
        (let ((paths (xm-query-path (car node-ids) (cadr node-ids))))
          (format-as-context paths))
        (retrieve-backlinks question))))  ; fallback
```

### Evaluation Loop

```scheme
;; evaluate.scm — Score predictions against ground truth

(define (evaluate-qa conversation strategy)
  "Run QA evaluation for a conversation."
  (let* ((qa-pairs (assoc-ref conversation "qa"))
         (results (map (lambda (qa)
                         (evaluate-single-qa qa strategy))
                       qa-pairs)))
    (compute-metrics results)))

(define (evaluate-single-qa qa strategy)
  "Evaluate single QA pair."
  (let* ((question (assoc-ref qa "question"))
         (ground-truth (assoc-ref qa "answer"))
         (category (assoc-ref qa "category"))
         (evidence (assoc-ref qa "evidence"))

         ;; Retrieve context using xm
         (context (retrieve-context question strategy))

         ;; Generate answer with LLM
         (prediction (generate-answer question context))

         ;; Compute token-level F1
         (f1 (compute-f1 prediction ground-truth)))

    `((question . ,question)
      (category . ,category)
      (ground-truth . ,ground-truth)
      (prediction . ,prediction)
      (f1 . ,f1)
      (context-tokens . ,(count-tokens context))
      (evidence-retrieved . ,(evidence-overlap context evidence)))))
```

## Metrics

### Primary Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| **F1 Score** | Token-level overlap with ground truth | Higher is better |
| **F1 by Category** | Breakdown by QA reasoning type | Multi-hop, temporal focus |
| **Event Graph F1** | Precision/recall on extracted events | Structure preservation |

### Efficiency Metrics

| Metric | Description | Why It Matters |
|--------|-------------|----------------|
| **Context Tokens** | Tokens in retrieved context | LLM cost/latency |
| **Retrieval Latency** | Time to query xm | Interactive use |
| **Evidence Recall** | % of ground-truth evidence retrieved | Retrieval quality |
| **Context Efficiency** | F1 / context tokens | Quality per token |

### Reporting Format

```json
{
  "condition": "xm-backlinks",
  "conversation_id": "conv_01",
  "overall_f1": 0.72,
  "by_category": {
    "single_hop": 0.81,
    "multi_hop": 0.68,
    "temporal": 0.74,
    "commonsense": 0.65,
    "adversarial": 0.52
  },
  "avg_context_tokens": 1842,
  "avg_retrieval_latency_ms": 23,
  "evidence_recall": 0.78
}
```

## Hypotheses

| ID | Hypothesis | Test |
|----|------------|------|
| H1 | xm outperforms flat retrieval on multi-hop QA | Compare F1(xm-path) vs F1(baseline-raw) on multi_hop category |
| H2 | SPARQL temporal constraints improve temporal QA | Compare F1(xm-sparql) vs F1(baseline-obs) on temporal category |
| H3 | Pre-structured causal links improve event extraction | Compare Event Graph F1(xm) vs F1(baseline) |
| H4 | xm achieves higher context efficiency | Compare F1/tokens across conditions |

### Falsification Criteria

If xm-based retrieval does **not** show statistically significant improvement on multi-hop or temporal QA categories compared to baseline-obs, then the linked-data approach may be over-engineered for conversational memory.

## Running the Evaluation

### Prerequisites

```bash
# Build xm
cd xm && cargo build --release

# Download LoCoMo dataset
curl -L -o eval/locomo/data/locomo10.json \
  "https://github.com/snap-research/locomo/raw/main/locomo10.json"
```

### Quick Start (Minimal Experiment)

```bash
# 1. Ingest first conversation
xm eval locomo ingest --conversation 0

# 2. Run multi-hop QA subset
xm eval locomo run \
  --conversation 0 \
  --category multi_hop \
  --conditions baseline-raw,xm-backlinks,xm-path

# 3. View results
xm eval locomo report --format table
```

### Full Evaluation

```bash
# Ingest all 10 conversations
xm eval locomo ingest --all

# Run all conditions across all tasks
xm eval locomo run \
  --all-conversations \
  --all-categories \
  --conditions baseline-raw,baseline-obs,xm-sparql,xm-backlinks,xm-path,xm-hybrid

# Generate report
xm eval locomo report --format json > results/full-eval.json
xm eval locomo report --format markdown > results/full-eval.md
```

### Ablation Studies

```bash
# Node granularity: per-turn vs per-session
xm eval locomo run --ablation node-granularity

# Link density: explicit only vs inferred
xm eval locomo run --ablation link-density

# Hybrid weighting: vary SPARQL vs embedding contribution
xm eval locomo run --ablation hybrid-weights
```

## Expected Outcomes

### Best Case

xm shows 10-20% F1 improvement on multi-hop and temporal categories, with 30-50% reduction in context tokens. This validates the linked-data hypothesis.

### Neutral Case

xm matches baseline-obs performance but with lower latency or fewer tokens. The structure provides efficiency rather than accuracy gains.

### Negative Case

xm underperforms baselines, suggesting that the overhead of maintaining graph structure doesn't pay off for conversational memory. Would indicate need to revisit the approach or focus xm on different use cases.

## References

- [LoCoMo Project Page](https://snap-research.github.io/locomo/)
- [LoCoMo GitHub Repository](https://github.com/snap-research/locomo)
- [ACL 2024 Paper](https://aclanthology.org/2024.acl-long.747.pdf)
- [arXiv Preprint](https://arxiv.org/abs/2402.17753)
