#!/usr/bin/env python3
"""
LoCoMo Benchmark Runner for xm
Uses Guile for retrieval, Python for LLM calls.

Usage:
    python3 eval/locomo/benchmark-runner.py --condition xm-sparql --limit 20
    python3 eval/locomo/benchmark-runner.py --compare --limit 15
"""

import json
import subprocess
import argparse
import os
import sys
import requests
from pathlib import Path
from dataclasses import dataclass
from typing import Optional, List, Tuple

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# Global model setting (can be overridden via --model)
MODEL = "claude-sonnet-4-20250514"


def call_claude(prompt: str, max_tokens: int = 100) -> str:
    """Call Claude API.

    Uses Claude Sonnet 4.5 by default following Backboard methodology
    which uses strong models (Gemini 2.5 Pro + GPT-4.1) for evaluation.
    """
    global MODEL
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY not set")

    response = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        },
        json={
            "model": MODEL,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]
        }
    )

    if response.status_code == 200:
        data = response.json()
        return data.get("content", [{}])[0].get("text", "")
    print(f"  API error: {response.status_code} - {response.text[:200]}")
    return ""


def retrieve_context(conv_id: str, question: str, condition: str) -> str:
    """Retrieve context from xm using Guile subprocess."""
    # Escape for Guile string
    q_escaped = question.replace('\\', '\\\\').replace('"', '\\"')

    guile_code = f'''
(use-modules (xm store)
             (eval locomo ingest)
             (eval locomo retrieve)
             (eval locomo conditions))

(define (get-string-all port)
  (let loop ((chars '()))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define store (make-memory-store))
(define json-str (call-with-input-file "eval/locomo/data/locomo10.json" get-string-all))
(define conversations (json-string->scm json-str))
(define conv (car conversations))
(ingest-conversation store conv)

(define retriever (make-retriever '{condition} #:max-tokens 4000))
(define result (retriever store "{conv_id}" "{q_escaped}"))
(display (assoc-ref result 'context))
(store-close store)
'''

    try:
        result = subprocess.run(
            ["guile", "-L", "guile", "-L", "eval/locomo", "-c", guile_code],
            capture_output=True, text=True, timeout=60
        )
        return result.stdout[:6000] if result.stdout else ""
    except Exception as e:
        print(f"  Retrieval error: {e}")
        return ""


def generate_answer(question: str, context: str) -> str:
    """Generate an answer using Claude.

    Follows Backboard methodology with conversation memory assistant role.
    """
    prompt = f"""You are a conversation memory assistant. Based on the retrieved conversation context below, answer the question concisely and directly.

If the answer cannot be determined from the context, say "Cannot determine from context".

Retrieved Context:
{context[:5000]}

Question: {question}

Answer (be brief and specific):"""
    return call_claude(prompt, 150)


def judge_answer(question: str, gold: str, generated: str) -> int:
    """Judge if answer is correct (1) or wrong (0).

    Follows Backboard methodology with generous grading:
    - Same topic/meaning counts as correct
    - Flexible date matching (May 7th vs 7 May)
    - Only factually different answers are wrong
    """
    prompt = f"""You are evaluating a question-answering system's response against a gold standard answer.

Question: {question}
Gold Answer: {gold}
Generated Answer: {generated}

Instructions:
- Be GENEROUS with your grading - as long as it touches on the same topic as the gold answer, count as CORRECT
- For time-related questions, be flexible: "May 7th" and "7 May" and "May 2023" all refer to the same period
- Only mark WRONG if the answer is factually different or completely misses the point
- "Cannot determine" should be WRONG if the gold answer has specific information

Respond with JSON: {{"reasoning": "one sentence explanation", "label": "CORRECT or WRONG"}}"""

    judgment = call_claude(prompt, 100)
    return 1 if "CORRECT" in judgment.upper() else 0


def run_evaluation(condition: str, limit: int = 20, verbose: bool = True):
    """Run evaluation for one condition."""
    print(f"\n{'='*65}")
    print(f"  LoCoMo Benchmark: {condition}")
    print(f"{'='*65}\n")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]
    conv_id = conv["sample_id"]

    # Filter QA (skip adversarial)
    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]

    print(f"Evaluating {len(qa_pairs)} questions from {conv_id}\n")

    results: List[Tuple[int, int]] = []  # (category, score)

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        q_display = question[:55] + "..." if len(question) > 55 else question
        print(f"[{i}/{len(qa_pairs)}] {q_display}")

        # 1. Retrieve context
        context = retrieve_context(conv_id, question, condition)

        # 2. Generate answer
        generated = generate_answer(question, context)

        # 3. Judge
        score = judge_answer(question, gold, generated)

        # Display
        gold_display = gold[:45] + "..." if len(gold) > 45 else gold
        gen_display = generated[:45] + "..." if len(generated) > 45 else generated

        print(f"   Expected: {gold_display}")
        print(f"   Got:      {gen_display}")
        print(f"   {'✓ CORRECT' if score == 1 else '✗ WRONG'}\n")

        results.append((category, score))

    # Calculate metrics
    print(f"\n{'='*65}")
    print(f"Results: {condition}")
    print(f"{'='*65}\n")

    print(f"{'Category':<15} {'Correct':>10} {'Total':>8} {'Accuracy':>10}")
    print("-" * 47)

    by_category = {}
    for cat_num in [1, 2, 3, 4]:
        cat_results = [r for r in results if r[0] == cat_num]
        if cat_results:
            correct = sum(r[1] for r in cat_results)
            total = len(cat_results)
            accuracy = correct / total * 100
            by_category[cat_num] = (correct, total, accuracy)
            print(f"{CATEGORY_NAMES[cat_num]:<15} {correct:>10} {total:>8} {accuracy:>9.1f}%")

    print("-" * 47)
    total = len(results)
    correct = sum(r[1] for r in results)
    accuracy = correct / total * 100 if total > 0 else 0
    print(f"{'OVERALL':<15} {correct:>10} {total:>8} {accuracy:>9.1f}%\n")

    return {
        "condition": condition,
        "total": total,
        "correct": correct,
        "accuracy": accuracy,
        "by_category": by_category
    }


def compare_conditions(conditions: List[str], limit: int = 15):
    """Compare multiple conditions."""
    print(f"\n{'='*70}")
    print("  LoCoMo Benchmark: Comparing Memory Retrieval Conditions")
    print(f"{'='*70}\n")

    results = []
    for cond in conditions:
        result = run_evaluation(cond, limit=limit, verbose=True)
        results.append(result)

    # Summary table
    print(f"\n{'='*70}")
    print("  COMPARISON SUMMARY")
    print(f"{'='*70}\n")

    print(f"{'Condition':<18} {'Single':>10} {'Temporal':>10} {'Multi':>10} {'OVERALL':>10}")
    print("-" * 60)

    for r in results:
        cond = r["condition"]
        by_cat = r["by_category"]

        def get_acc(cat_num):
            if cat_num in by_cat:
                return by_cat[cat_num][2]
            return 0.0

        print(f"{cond:<18} {get_acc(1):>9.1f}% {get_acc(2):>9.1f}% "
              f"{get_acc(4):>9.1f}% {r['accuracy']:>9.1f}%")

    print()

    # Find best
    best = max(results, key=lambda x: x["accuracy"])
    baseline = next((r for r in results if r["condition"] == "baseline-raw"), None)

    if baseline and best["condition"] != "baseline-raw":
        improvement = best["accuracy"] - baseline["accuracy"]
        print(f"🏆 Best: {best['condition']} ({best['accuracy']:.1f}%)")
        print(f"   vs baseline: +{improvement:.1f}%\n")


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Benchmark for xm")
    parser.add_argument("--condition", default="xm-sparql",
                       help="Condition to test")
    parser.add_argument("--compare", action="store_true",
                       help="Compare multiple conditions")
    parser.add_argument("--conditions", default="baseline-raw,xm-sparql,xm-hybrid",
                       help="Conditions for comparison")
    parser.add_argument("--limit", type=int, default=20,
                       help="Max questions")
    parser.add_argument("--model", default="claude-sonnet-4-20250514",
                       help="Claude model to use (default: claude-sonnet-4-20250514)")

    args = parser.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY not set")
        sys.exit(1)

    # Store model choice globally for call_claude
    global MODEL
    MODEL = args.model
    print(f"Using model: {MODEL}\n")

    if args.compare:
        conditions = args.conditions.split(",")
        compare_conditions(conditions, limit=args.limit)
    else:
        run_evaluation(args.condition, limit=args.limit)


if __name__ == "__main__":
    main()
