#!/usr/bin/env python3
"""
LoCoMo Benchmark Runner for xm

Evaluates xm's SPARQL-based memory retrieval against the LoCoMo benchmark
using the same LLM-judge methodology as Memobase and Backboard.

Usage:
    # Set API key
    export ANTHROPIC_API_KEY=your_key_here

    # Run evaluation (from xm directory)
    python3 eval/locomo/run-benchmark.py --condition xm-sparql --limit 50

    # Compare conditions
    python3 eval/locomo/run-benchmark.py --compare --limit 30
"""

import json
import subprocess
import argparse
import os
import sys
from pathlib import Path
from typing import Optional
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor

# Ensure we're in the xm directory
XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)


@dataclass
class EvalResult:
    question: str
    category: int
    gold_answer: str
    generated_answer: str
    score: int  # 1 = correct, 0 = wrong
    context_length: int


CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# LLM Judge prompt (following Memobase/Backboard methodology)
JUDGE_PROMPT = """You are evaluating a question-answering system's response against a gold standard answer.

Question: {question}
Gold Answer: {gold_answer}
Generated Answer: {generated_answer}

Instructions:
- Label as 'CORRECT' if the generated answer conveys the same essential information as the gold answer
- Be generous: as long as it touches on the same topic/meaning, count it as CORRECT
- For time-related answers, flexible matching is acceptable (e.g., "May 2023" vs "7 May 2023")
- Label as 'WRONG' only if the answer is factually different or completely misses the point

Respond with ONLY one word: CORRECT or WRONG"""

ANSWER_PROMPT = """Based on the following conversation context, answer the question concisely.
If the answer cannot be determined from the context, say "Cannot determine".

Context:
{context}

Question: {question}

Answer (be brief and direct):"""


def call_claude(prompt: str, max_tokens: int = 200) -> str:
    """Call Claude API using curl."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY environment variable not set")

    import json as json_mod
    escaped_prompt = json_mod.dumps(prompt)[1:-1]  # Remove quotes, keep escaping

    cmd = [
        "curl", "-s", "https://api.anthropic.com/v1/messages",
        "-H", "Content-Type: application/json",
        "-H", f"x-api-key: {api_key}",
        "-H", "anthropic-version: 2023-06-01",
        "-d", json_mod.dumps({
            "model": "claude-3-haiku-20240307",
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]
        })
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    try:
        response = json_mod.loads(result.stdout)
        return response.get("content", [{}])[0].get("text", "")
    except:
        return ""


def retrieve_context_xm(conv_id: str, question: str, condition: str) -> str:
    """Retrieve context from xm using Guile."""
    guile_code = f'''
(use-modules (xm store)
             (eval locomo ingest)
             (eval locomo retrieve)
             (eval locomo conditions))

(define store (make-memory-store))
(define data-path "eval/locomo/data/locomo10.json")

(define (get-string-all port)
  (let loop ((chars (quote ())))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define json-str (call-with-input-file data-path get-string-all))
(define conversations (json-string->scm json-str))
(define conv (find (lambda (c) (equal? (assoc-ref c "sample_id") "{conv_id}")) conversations))

(when conv (ingest-conversation store conv))

(define retriever (make-retriever (quote {condition}) #:max-tokens 4000))
(define result (retriever store "{conv_id}" "{question.replace('"', '\\"')}"))
(display (assoc-ref result (quote context)))
(store-close store)
'''

    cmd = ["guile", "-L", "guile", "-L", "eval/locomo", "-c", guile_code]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return result.stdout[:8000] if result.stdout else ""


def evaluate_single(qa: dict, conv_id: str, condition: str, verbose: bool = False) -> Optional[EvalResult]:
    """Evaluate a single QA pair."""
    question = qa["question"]
    gold_answer = str(qa["answer"])
    category = qa["category"]

    try:
        # 1. Retrieve context
        context = retrieve_context_xm(conv_id, question, condition)
        if not context:
            return None

        # 2. Generate answer
        answer_prompt = ANSWER_PROMPT.format(context=context[:6000], question=question)
        generated = call_claude(answer_prompt, max_tokens=100)

        # 3. Judge answer
        judge_prompt = JUDGE_PROMPT.format(
            question=question,
            gold_answer=gold_answer,
            generated_answer=generated
        )
        judgment = call_claude(judge_prompt, max_tokens=10)
        score = 1 if "CORRECT" in judgment.upper() else 0

        if verbose:
            status = "✓" if score == 1 else "✗"
            print(f"  {status} [{CATEGORY_NAMES[category]}] {question[:50]}...")

        return EvalResult(
            question=question,
            category=category,
            gold_answer=gold_answer,
            generated_answer=generated,
            score=score,
            context_length=len(context)
        )
    except Exception as e:
        if verbose:
            print(f"  ⚠ Error: {e}")
        return None


def run_evaluation(condition: str, limit: int = 50, verbose: bool = True) -> dict:
    """Run full evaluation for a condition."""
    print(f"\n{'='*60}")
    print(f"Evaluating: {condition}")
    print(f"{'='*60}\n")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]  # First conversation
    conv_id = conv["sample_id"]

    # Filter QA (skip category 5 = adversarial)
    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]

    print(f"Testing {len(qa_pairs)} questions from {conv_id}")
    print()

    # Pre-ingest the conversation once
    ingest_code = '''
(use-modules (xm store) (eval locomo ingest))
(define store (make-memory-store))
(define (get-string-all port)
  (let loop ((chars (quote ())))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))
(define json-str (call-with-input-file "eval/locomo/data/locomo10.json" get-string-all))
(define conversations (json-string->scm json-str))
(ingest-conversation store (car conversations))
(store-close store)
(display "OK")
'''
    subprocess.run(["guile", "-L", "guile", "-L", "eval/locomo", "-c", ingest_code],
                   capture_output=True, timeout=120)

    # Run evaluations
    results = []
    for i, qa in enumerate(qa_pairs, 1):
        if verbose:
            print(f"[{i}/{len(qa_pairs)}] ", end="", flush=True)

        result = evaluate_single(qa, conv_id, condition, verbose=False)
        if result:
            results.append(result)
            if verbose:
                status = "✓" if result.score == 1 else "✗"
                print(f"{status} {result.question[:45]}...")
        else:
            if verbose:
                print(f"⚠ Skipped")

    # Calculate metrics
    by_category = {}
    for cat_num, cat_name in CATEGORY_NAMES.items():
        if cat_num == 5:
            continue
        cat_results = [r for r in results if r.category == cat_num]
        if cat_results:
            accuracy = sum(r.score for r in cat_results) / len(cat_results)
            by_category[cat_name] = {
                "count": len(cat_results),
                "correct": sum(r.score for r in cat_results),
                "accuracy": accuracy
            }

    overall = sum(r.score for r in results) / len(results) if results else 0

    # Print results
    print(f"\n{'='*60}")
    print(f"Results: {condition}")
    print(f"{'='*60}")
    print(f"{'Category':<15} {'Correct':>10} {'Total':>8} {'Accuracy':>10}")
    print("-" * 45)

    for cat_name, data in by_category.items():
        print(f"{cat_name:<15} {data['correct']:>10} {data['count']:>8} {data['accuracy']*100:>9.1f}%")

    print("-" * 45)
    print(f"{'OVERALL':<15} {sum(r.score for r in results):>10} {len(results):>8} {overall*100:>9.1f}%")
    print()

    return {
        "condition": condition,
        "total": len(results),
        "overall_accuracy": overall,
        "by_category": by_category
    }


def compare_conditions(conditions: list, limit: int = 30) -> None:
    """Compare multiple conditions."""
    print("\n" + "="*70)
    print("LoCoMo Benchmark: Comparing Memory Retrieval Conditions")
    print("="*70 + "\n")

    results = []
    for cond in conditions:
        result = run_evaluation(cond, limit=limit, verbose=False)
        results.append(result)

    # Summary comparison
    print("\n" + "="*70)
    print("COMPARISON SUMMARY")
    print("="*70)
    print(f"\n{'Condition':<18} {'Single':>10} {'Temporal':>10} {'Multi':>10} {'Common':>10} {'OVERALL':>10}")
    print("-" * 70)

    for result in results:
        cond = result["condition"]
        by_cat = result["by_category"]

        def get_acc(name):
            return by_cat.get(name, {}).get("accuracy", 0) * 100

        overall = result["overall_accuracy"] * 100
        print(f"{cond:<18} {get_acc('single_hop'):>9.1f}% {get_acc('temporal'):>9.1f}% "
              f"{get_acc('multi_hop'):>9.1f}% {get_acc('commonsense'):>9.1f}% {overall:>9.1f}%")

    print("\n" + "="*70)

    # Find winner
    best = max(results, key=lambda r: r["overall_accuracy"])
    baseline = next((r for r in results if r["condition"] == "baseline-raw"), None)

    if baseline and best["condition"] != "baseline-raw":
        improvement = (best["overall_accuracy"] - baseline["overall_accuracy"]) * 100
        print(f"\n🏆 Best: {best['condition']} ({best['overall_accuracy']*100:.1f}%)")
        print(f"   Improvement over baseline: +{improvement:.1f}%")


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Benchmark for xm")
    parser.add_argument("--condition", default="xm-sparql",
                       help="Retrieval condition (baseline-raw, xm-sparql, xm-hybrid, etc.)")
    parser.add_argument("--compare", action="store_true",
                       help="Compare multiple conditions")
    parser.add_argument("--conditions", default="baseline-raw,xm-sparql,xm-hybrid",
                       help="Comma-separated conditions for comparison")
    parser.add_argument("--limit", type=int, default=50,
                       help="Max questions to evaluate")
    parser.add_argument("--verbose", "-v", action="store_true",
                       help="Verbose output")

    args = parser.parse_args()

    # Check API key
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY environment variable not set")
        print("Set it with: export ANTHROPIC_API_KEY=your_key_here")
        sys.exit(1)

    if args.compare:
        conditions = args.conditions.split(",")
        compare_conditions(conditions, limit=args.limit)
    else:
        run_evaluation(args.condition, limit=args.limit, verbose=args.verbose)


if __name__ == "__main__":
    main()
