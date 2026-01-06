#!/usr/bin/env python3
"""
LoCoMo Agentic Evaluation using Claude Agent SDK

This evaluation gives an LLM agent access to
xm CLI tools via Bash. The agent can interactively query the knowledge graph
to answer questions - testing whether SPARQL-based memory is useful when
an agent can actively explore it.

Two phases:
1. Ingestion: Script pre-ingests conversation into xm (deterministic)
2. Retrieval: Agent uses xm CLI to answer questions (agentic)

Usage:
    pip install claude-agent-sdk
    export ANTHROPIC_API_KEY=your_key
    python3 eval/locomo/agentic-eval.py --limit 10
"""

import asyncio
import json
import subprocess
import argparse
import os
import sys
import tempfile
import shutil
from pathlib import Path
from typing import Dict, Any, List, Tuple
import requests

try:
    from claude_agent_sdk import query, ClaudeAgentOptions
    HAS_AGENT_SDK = True
except ImportError:
    HAS_AGENT_SDK = False
    print("Warning: claude-agent-sdk not installed, using API fallback")

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "claude-sonnet-4-20250514"

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# System prompt for the question-answering agent
QA_AGENT_SYSTEM = """You are a question-answering agent with access to a structured knowledge graph memory system called xm.

## Available xm Commands (use via Bash)

You can query the knowledge graph using these commands:

1. **Search by text content**:
   ```bash
   ./bin/xm --store {store_path} query sparql "SELECT ?s ?content WHERE {{ ?s <https://xm.dev/ns/v1#content> ?content . FILTER(CONTAINS(LCASE(?content), 'keyword')) }} LIMIT 20"
   ```

2. **Find all utterances from a speaker**:
   ```bash
   ./bin/xm --store {store_path} query sparql "SELECT ?u ?content WHERE {{ ?u <https://xm.dev/ns/v1#speaker> 'Caroline' . ?u <https://xm.dev/ns/v1#content> ?content }} LIMIT 20"
   ```

3. **Find utterances with timestamps**:
   ```bash
   ./bin/xm --store {store_path} query sparql "SELECT ?u ?content ?ts WHERE {{ ?u a <https://xm.dev/ns/v1#Utterance> . ?u <https://xm.dev/ns/v1#content> ?content . ?u <http://purl.org/dc/terms/created> ?ts }} ORDER BY ?ts LIMIT 20"
   ```

4. **Find events**:
   ```bash
   ./bin/xm --store {store_path} query sparql "SELECT ?e ?label WHERE {{ ?e a <http://www.w3.org/ns/prov#Activity> . ?e <http://www.w3.org/2000/01/rdf-schema#label> ?label }} LIMIT 20"
   ```

5. **Find observations about a person**:
   ```bash
   ./bin/xm --store {store_path} query sparql "SELECT ?obs ?content WHERE {{ ?obs a <https://xm.dev/ns/v1#Observation> . ?obs <https://xm.dev/ns/v1#content> ?content . FILTER(CONTAINS(?content, 'Caroline')) }}"
   ```

## Strategy

1. Start by searching for keywords from the question
2. If the question is about timing, look for timestamps
3. If about a person, search for their utterances or observations about them
4. Follow references to get more context
5. Once you have enough information, provide your final answer

## Important Notes
- The knowledge graph contains conversations between Caroline and Melanie
- Utterances have speaker, content, timestamp, and session info
- Events capture activities mentioned in conversations
- Observations are facts learned about people

When you have enough information to answer, provide your answer clearly.
If you cannot find the information after searching, say "Cannot determine from memory".
"""


def ingest_conversation_to_xm(conv: Dict, store_path: str) -> bool:
    """Pre-ingest conversation into xm using Guile.

    Note: Uses in-memory store since file-based stores need special setup.
    The store_path is used as an identifier but actual storage is in-memory.
    """
    conv_id = conv["sample_id"]

    # For the agentic eval, we'll use the default store location
    # and let the CLI handle persistence
    guile_code = '''
(use-modules (xm store)
             (eval locomo ingest))

(define (get-string-all port)
  (let loop ((chars (quote ())))
    (let ((c (read-char port)))
      (if (eof-object? c)
          (list->string (reverse chars))
          (loop (cons c chars))))))

(define store (make-memory-store))
(define json-str (call-with-input-file "eval/locomo/data/locomo10.json" get-string-all))
(define conversations (json-string->scm json-str))
(define conv (car conversations))
(ingest-conversation store conv)

;; Query to verify
(define graph-uri "https://xm.dev/ns/v1#graph/locomo/conv-26")
(define query (format #f "SELECT (COUNT(*) as ?count) FROM <~a> WHERE { ?s ?p ?o }" graph-uri))
(define results (store-query store query))
(display results)
(newline)
(store-close store)
'''

    try:
        result = subprocess.run(
            ["guile", "-L", "guile", "-L", "eval/locomo", "-c", guile_code],
            capture_output=True, text=True, timeout=120
        )
        # Check if we got a positive count
        if '"value":"0"' not in result.stdout and '"count"' in result.stdout:
            return True
        print(f"Ingestion result: {result.stdout[:200]}")
        print(f"Stderr: {result.stderr[:200]}" if result.stderr else "")
        return False
    except Exception as e:
        print(f"Ingestion error: {e}")
        return False


async def answer_with_agent_sdk(question: str, store_path: str, verbose: bool = True) -> str:
    """Use Claude Agent SDK to answer question via xm CLI."""

    system_prompt = QA_AGENT_SYSTEM.format(store_path=store_path)

    prompt = f"""Answer this question about the conversation by querying the xm knowledge graph:

Question: {question}

Use the xm query commands via Bash to find the relevant information. Start by searching for key terms from the question."""

    options = ClaudeAgentOptions(
        allowed_tools=["Bash", "Read"],
        model="sonnet",
        cwd=str(XM_DIR),
        system_prompt=system_prompt,
        max_turns=8,  # Limit iterations
    )

    response_text = []

    try:
        async for message in query(prompt=prompt, options=options):
            if hasattr(message, 'content'):
                content = message.content
                if isinstance(content, str):
                    response_text.append(content)
                elif isinstance(content, list):
                    for block in content:
                        if hasattr(block, 'text'):
                            response_text.append(block.text)
                        if verbose and hasattr(block, 'name'):
                            # Tool use
                            tool_input = getattr(block, 'input', {})
                            if block.name == 'Bash':
                                cmd = tool_input.get('command', '')[:80]
                                print(f"    [Bash] {cmd}...")
            elif hasattr(message, 'text'):
                response_text.append(message.text)

    except Exception as e:
        print(f"Agent error: {e}")
        return "Error querying memory"

    return "\n".join(response_text)


def answer_with_api_fallback(question: str, store_path: str, verbose: bool = True) -> str:
    """Fallback: Use raw API with tool_use for xm queries."""

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY not set")

    system_prompt = QA_AGENT_SYSTEM.format(store_path=store_path)

    tools = [{
        "name": "bash",
        "description": "Execute a bash command. Use this to run xm CLI queries.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The bash command to execute"}
            },
            "required": ["command"]
        }
    }]

    messages = [{
        "role": "user",
        "content": f"Answer this question by querying xm:\n\nQuestion: {question}\n\nUse bash to run ./bin/xm commands."
    }]

    for i in range(6):  # Max 6 rounds
        response = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01"
            },
            json={
                "model": MODEL,
                "max_tokens": 1024,
                "system": system_prompt,
                "tools": tools,
                "messages": messages
            }
        )

        if response.status_code != 200:
            return f"API error: {response.status_code}"

        result = response.json()
        content = result.get("content", [])
        stop_reason = result.get("stop_reason", "")

        # Check for tool use
        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses or stop_reason == "end_turn":
            # Agent is done - extract text answer
            text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return "\n".join(text_parts)

        # Execute tool calls
        tool_results = []
        for tool_use in tool_uses:
            if tool_use["name"] == "bash":
                cmd = tool_use["input"].get("command", "")
                if verbose:
                    print(f"    [Bash] {cmd[:80]}...")

                try:
                    proc = subprocess.run(
                        cmd, shell=True, capture_output=True, text=True,
                        timeout=30, cwd=XM_DIR
                    )
                    output = proc.stdout[:3000] if proc.stdout else proc.stderr[:1000]
                except Exception as e:
                    output = f"Error: {e}"

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tool_use["id"],
                    "content": output
                })

        messages.append({"role": "assistant", "content": content})
        messages.append({"role": "user", "content": tool_results})

    return "Max iterations reached"


def judge_answer(question: str, gold: str, generated: str) -> int:
    """Judge if answer is correct."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")

    prompt = f"""You are evaluating a QA system response.

Question: {question}
Expected Answer: {gold}
Generated Answer: {generated}

Be GENEROUS - same meaning/topic counts as correct.
For dates, flexible matching is OK (May 7th = 7 May).

Respond with JSON: {{"reasoning": "brief explanation", "label": "CORRECT or WRONG"}}"""

    response = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        },
        json={
            "model": MODEL,
            "max_tokens": 100,
            "messages": [{"role": "user", "content": prompt}]
        }
    )

    if response.status_code == 200:
        content = response.json().get("content", [])
        if content:
            text = content[0].get("text", "")
            return 1 if "CORRECT" in text.upper() else 0
    return 0


async def run_agentic_eval(limit: int = 10, verbose: bool = True):
    """Run the agentic evaluation."""

    print(f"\n{'='*70}")
    print("  LoCoMo Agentic Evaluation")
    print(f"  Model: {MODEL}")
    print(f"  Agent SDK: {'Yes' if HAS_AGENT_SDK else 'No (using API fallback)'}")
    print(f"{'='*70}\n")

    # Create temp store
    store_path = tempfile.mkdtemp(prefix="xm-eval-")
    print(f"Store: {store_path}\n")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]
    conv_id = conv["sample_id"]

    # Phase 1: Ingest
    print("Phase 1: Ingesting conversation into xm...")
    if not ingest_conversation_to_xm(conv, store_path):
        print("ERROR: Failed to ingest conversation")
        return

    # Verify ingestion
    verify = subprocess.run(
        ["./bin/xm", "--store", store_path, "query", "sparql",
         "SELECT (COUNT(*) as ?count) WHERE { ?s ?p ?o }"],
        capture_output=True, text=True
    )
    print(f"  Triples in store: {verify.stdout.strip()}\n")

    # Phase 2: Answer questions
    print("Phase 2: Agentic Question Answering")
    print("-" * 50)

    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]
    results: List[Tuple[int, int]] = []

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        q_display = question[:50] + "..." if len(question) > 50 else question
        print(f"\n[{i}/{len(qa_pairs)}] {q_display}")

        # Get agent's answer
        if HAS_AGENT_SDK:
            generated = await answer_with_agent_sdk(question, store_path, verbose)
        else:
            generated = answer_with_api_fallback(question, store_path, verbose)

        # Judge
        score = judge_answer(question, gold, generated)

        gold_display = gold[:40] + "..." if len(gold) > 40 else gold
        gen_display = generated[:60] + "..." if len(generated) > 60 else generated

        print(f"  Expected: {gold_display}")
        print(f"  Got:      {gen_display}")
        print(f"  {'✓ CORRECT' if score == 1 else '✗ WRONG'}")

        results.append((category, score))

    # Print results
    print(f"\n{'='*70}")
    print("Results: Agentic xm")
    print(f"{'='*70}\n")

    print(f"{'Category':<15} {'Correct':>10} {'Total':>8} {'Accuracy':>10}")
    print("-" * 47)

    for cat_num in [1, 2, 3, 4]:
        cat_results = [r for r in results if r[0] == cat_num]
        if cat_results:
            correct = sum(r[1] for r in cat_results)
            total = len(cat_results)
            accuracy = correct / total * 100
            print(f"{CATEGORY_NAMES[cat_num]:<15} {correct:>10} {total:>8} {accuracy:>9.1f}%")

    print("-" * 47)
    total = len(results)
    correct = sum(r[1] for r in results)
    accuracy = correct / total * 100 if total > 0 else 0
    print(f"{'OVERALL':<15} {correct:>10} {total:>8} {accuracy:>9.1f}%\n")

    # Cleanup
    shutil.rmtree(store_path, ignore_errors=True)

    return {"total": total, "correct": correct, "accuracy": accuracy}


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Agentic Evaluation")
    parser.add_argument("--limit", type=int, default=10, help="Max questions")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show agent queries")

    args = parser.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY not set")
        sys.exit(1)

    asyncio.run(run_agentic_eval(limit=args.limit, verbose=args.verbose))


if __name__ == "__main__":
    main()
