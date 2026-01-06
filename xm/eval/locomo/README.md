# LoCoMo Evaluation for xm

Empirical validation of xm's SPARQL-based graph memory using the LoCoMo benchmark.

**Aligned with official LoCoMo specification**: https://github.com/snap-research/locomo

## Overview

This evaluation tests whether xm's linked-data approach (RDF triples, bidirectional links,
SPARQL queries) provides measurable benefits over flat retrieval for long-term conversational
memory tasks.

## LoCoMo Specification Alignment

This implementation follows the official LoCoMo evaluation methodology from the ACL 2024 paper
"Evaluating Very Long-Term Conversational Memory of LLM Agents" by Maharana et al.

### Metrics (LoCoMo-aligned)

| Metric | Description | Implementation |
|--------|-------------|----------------|
| **F1 Score** | Primary metric - token-level overlap with stemming | `compute_token_f1()` |
| **Category F1** | Category-specific scoring per LoCoMo spec | `compute_category_f1()` |
| **LLM Judge** | Secondary metric - binary correctness | `judge_answer()` |

### Answer Normalization

Following LoCoMo's `normalize_answer()` function:
1. Lowercase text
2. Remove punctuation
3. Remove articles (a, an, the, and)
4. Normalize whitespace

### Category-Specific Scoring

| Category | Scoring Method |
|----------|----------------|
| 1 (single_hop) | Max F1 across comma-separated answer parts |
| 2 (temporal) | Standard token F1 |
| 3 (commonsense) | Standard token F1 |
| 4 (multi_hop) | Standard token F1 |
| 5 (adversarial) | Binary check for "no information" phrases |

## Quick Start

```bash
# From the xm directory
cd /path/to/xm

# Run a quick sanity test (single conversation, limited QA)
guile -L guile -L eval/locomo -e '(eval locomo runner)' -c '
  (use-modules (eval locomo runner))
  (display (run-quick-test))
'

# Or using the xm CLI (once integrated)
xm eval locomo quick-test
```

## Running Evaluations

### Compare Conditions

```bash
# Compare baseline vs xm approaches
xm eval locomo compare \
  --conditions baseline-raw,xm-sparql,xm-hybrid \
  --limit 50 \
  --verbose
```

### Focus on Specific Question Types

```bash
# Test multi-hop reasoning (category 4)
xm eval locomo run \
  --condition xm-path \
  --category 4 \
  --verbose

# Test temporal queries (category 2)
xm eval locomo run \
  --condition xm-events \
  --category 2 \
  --verbose
```

### Full Evaluation

```bash
# Run all conditions across all data
xm eval locomo compare \
  --conditions baseline-raw,baseline-obs,xm-sparql,xm-backlinks,xm-path,xm-hybrid \
  --format json > results/full-eval.json
```

## Retrieval Conditions

| Condition | Description | Best For |
|-----------|-------------|----------|
| `baseline-raw` | Raw dialog text (control) | Baseline comparison |
| `baseline-obs` | Observations as flat text | Observation quality |
| `xm-sparql` | SPARQL text search | General retrieval |
| `xm-backlinks` | Entity-based traversal | Entity-centric questions |
| `xm-path` | Graph path queries | Multi-hop reasoning |
| `xm-observations` | Pre-extracted observations | Efficiency testing |
| `xm-events` | Event summaries with dates | Temporal queries |
| `xm-hybrid` | Combined strategies | Overall best performance |

## QA Categories

| Category | Name | Description |
|----------|------|-------------|
| 1 | single_hop | Direct fact retrieval |
| 2 | temporal | Time-based reasoning |
| 3 | commonsense | World knowledge integration |
| 4 | multi_hop | Reasoning across multiple facts |
| 5 | adversarial | Questions with no answer in context |

## Hypotheses Being Tested

1. **H1**: xm outperforms flat retrieval on multi-hop QA
   - Test: Compare F1(xm-path) vs F1(baseline-raw) on category 4

2. **H2**: SPARQL temporal constraints improve temporal QA
   - Test: Compare F1(xm-events) vs F1(baseline-obs) on category 2

3. **H3**: Pre-structured observations are more efficient
   - Test: Compare F1/context_tokens across conditions

4. **H4**: Hybrid retrieval provides best overall performance
   - Test: Compare F1(xm-hybrid) vs all other conditions

## Interpreting Results

### Positive Outcome
- xm-hybrid shows 10-20% F1 improvement on multi-hop and temporal categories
- Significant reduction in context tokens needed for same F1
- This validates the linked-data hypothesis

### Neutral Outcome
- xm matches baseline-obs performance but with lower latency or fewer tokens
- Structure provides efficiency rather than accuracy gains

### Negative Outcome
- xm underperforms baselines
- Would indicate need to revisit the approach or focus xm on different use cases

## File Structure

```
eval/locomo/
├── README.md              # This file
├── agentic-memory.py      # Agentic memory evaluation (Python, LoCoMo-aligned)
├── agentic-eval.py        # Alternative agentic evaluation
├── ingest.scm             # LoCoMo → xm ingestion (Scheme)
├── retrieve.scm           # Query strategies
├── evaluate.scm           # Scoring (LoCoMo-aligned F1, category-specific)
├── llm-judge.scm          # LLM-based judging
├── conditions.scm         # Experimental conditions
├── runner.scm             # CLI and orchestration
├── benchmark.scm          # Benchmark definitions
├── data/
│   └── locomo10.json      # LoCoMo dataset (10 conversations)
└── results/
    └── .gitkeep           # Evaluation results
```

## Running Agentic Memory Evaluation

The agentic memory evaluation (`agentic-memory.py`) tests whether an LLM agent can:
1. **Structure** memories from conversations (decide what to remember)
2. **Query** those memories to answer questions

```bash
# Set API key (OpenAI or Anthropic based on API_PROVIDER setting)
export OPENAI_API_KEY=your_key  # or ANTHROPIC_API_KEY

# Run evaluation with F1 and LLM judge metrics
python3 eval/locomo/agentic-memory.py --limit 20

# Ingest only (inspect memory structure)
python3 eval/locomo/agentic-memory.py --ingest-only --show-schema
```

### Output Metrics

The evaluation reports both LoCoMo-aligned metrics:

```
F1 SCORES (LoCoMo Primary Metric)
=================================================================
Category        Avg F1     Total
-----------------------------------
single_hop       0.450        5
temporal         0.380        8
...

LLM JUDGE SCORES (Binary Accuracy)
=================================================================
Category        Correct     Total   Accuracy
-----------------------------------------------
single_hop           3         5      60.0%
temporal             4         8      50.0%
...
```

## Development

### Running from Guile REPL

```scheme
(add-to-load-path "guile")
(add-to-load-path "eval/locomo")

(use-modules (eval locomo runner))
(use-modules (eval locomo ingest))
(use-modules (eval locomo retrieve))
(use-modules (eval locomo evaluate))
(use-modules (eval locomo conditions))

;; Run quick test
(run-quick-test #:verbose #t)

;; Or step by step:
(use-modules (xm store))
(define store (make-memory-store))

;; Ingest a conversation
(define convs (json-string->scm (call-with-input-file "eval/locomo/data/locomo10.json" get-string-all)))
(ingest-conversation store (car convs) #:verbose #t)

;; Test retrieval
(retrieve-context store "conv-26" "When did Caroline attend the support group?" 'xm-sparql)
```

## References

- [LoCoMo Project Page](https://snap-research.github.io/locomo/)
- [LoCoMo GitHub](https://github.com/snap-research/locomo)
- [ACL 2024 Paper](https://aclanthology.org/2024.acl-long.747.pdf)
- [arXiv](https://arxiv.org/abs/2402.17753)

### Citation

```bibtex
@inproceedings{maharana2024locomo,
  title={Evaluating Very Long-Term Conversational Memory of LLM Agents},
  author={Maharana, Adyasha and Lee, Dong-Ho and Tulyakov, Sergey and
          Bansal, Mohit and Barbieri, Francesco and Fang, Yuwei},
  booktitle={ACL},
  year={2024}
}
```

## Implementation Notes

### Differences from Official LoCoMo

1. **Stemming**: Uses simplified suffix-stripping instead of Porter Stemmer
   (for Scheme compatibility). For exact matching, use NLTK's PorterStemmer.

2. **BERT Score / ROUGE-L**: Not implemented. F1 is the primary metric per LoCoMo.

3. **Event Summarization / Multimodal**: Not implemented. Focus is on QA task.

### Extending the Evaluation

To add new retrieval conditions, edit `conditions.scm` and implement:
- `make-retriever` for the condition
- Add to `*available-conditions*` list
