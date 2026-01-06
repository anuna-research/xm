#!/usr/bin/env python3
"""
LoCoMo Agentic Benchmark for xm

Tests whether an LLM agent can effectively use xm's SPARQL-based memory
through interactive tool calls, following Backboard's agentic approach.

Two phases:
1. Ingestion: Agent processes conversation and stores memories via xm CLI
2. Retrieval: Agent queries xm iteratively to answer questions

Usage:
    export ANTHROPIC_API_KEY=your_key
    python3 eval/locomo/agentic-benchmark.py --limit 10
"""

import json
import subprocess
import argparse
import os
import sys
import re
from pathlib import Path
from typing import Optional, List, Dict, Any
from dataclasses import dataclass
import requests

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "claude-sonnet-4-20250514"
MAX_TOOL_CALLS = 5  # Max xm queries per question

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# Tool definitions for the agent
XM_TOOLS = [
    {
        "name": "xm_node_create",
        "description": "Create a new knowledge node in xm memory. Use for storing facts, events, people, etc.",
        "input_schema": {
            "type": "object",
            "properties": {
                "node_type": {
                    "type": "string",
                    "description": "Type of node: entity, event, observation, utterance"
                },
                "properties": {
                    "type": "object",
                    "description": "Key-value properties for the node (name, content, timestamp, etc.)"
                }
            },
            "required": ["node_type", "properties"]
        }
    },
    {
        "name": "xm_link_create",
        "description": "Create a link between two nodes to capture relationships.",
        "input_schema": {
            "type": "object",
            "properties": {
                "from_node": {"type": "string", "description": "Source node ID"},
                "to_node": {"type": "string", "description": "Target node ID"},
                "predicate": {"type": "string", "description": "Relationship type (e.g., said, experienced, mentions)"}
            },
            "required": ["from_node", "to_node", "predicate"]
        }
    },
    {
        "name": "xm_query_sparql",
        "description": "Execute a SPARQL query to search the knowledge graph. Use for finding specific facts, filtering by properties, or complex queries.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "SPARQL SELECT query. Use prefixes: xm: <https://xm.dev/ns/v1#>, prov: <http://www.w3.org/ns/prov#>"
                }
            },
            "required": ["query"]
        }
    },
    {
        "name": "xm_query_nodes",
        "description": "Search for nodes by type or text content.",
        "input_schema": {
            "type": "object",
            "properties": {
                "node_type": {"type": "string", "description": "Filter by node type (entity, event, utterance)"},
                "contains": {"type": "string", "description": "Text to search for in node content"}
            }
        }
    },
    {
        "name": "xm_query_backlinks",
        "description": "Find all nodes that link TO a target node. Useful for finding context around an entity.",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_node": {"type": "string", "description": "Node ID to find backlinks for"}
            },
            "required": ["target_node"]
        }
    },
    {
        "name": "xm_node_get",
        "description": "Get full details of a specific node including all properties and links.",
        "input_schema": {
            "type": "object",
            "properties": {
                "node_id": {"type": "string", "description": "The node ID to retrieve"}
            },
            "required": ["node_id"]
        }
    }
]


def call_claude(messages: List[Dict], tools: List[Dict] = None, max_tokens: int = 1024) -> Dict:
    """Call Claude API with optional tools."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY not set")

    payload = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": messages
    }
    if tools:
        payload["tools"] = tools

    response = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        },
        json=payload
    )

    if response.status_code == 200:
        return response.json()
    print(f"API error: {response.status_code} - {response.text[:300]}")
    return {"content": [{"type": "text", "text": "API error"}]}


def execute_xm_tool(tool_name: str, tool_input: Dict, store_path: str) -> str:
    """Execute an xm CLI command and return the result."""
    try:
        if tool_name == "xm_node_create":
            props = tool_input.get("properties", {})
            prop_args = []
            for k, v in props.items():
                prop_args.extend(["-p", f"{k}={v}"])
            cmd = ["./bin/xm", "--store", store_path, "--json", "node", "create",
                   "-t", tool_input.get("node_type", "entity")] + prop_args

        elif tool_name == "xm_link_create":
            cmd = ["./bin/xm", "--store", store_path, "--json", "link", "create",
                   "--from", tool_input["from_node"],
                   "--to", tool_input["to_node"],
                   "--predicate", tool_input.get("predicate", "xm:references")]

        elif tool_name == "xm_query_sparql":
            cmd = ["./bin/xm", "--store", store_path, "--json", "query", "sparql",
                   tool_input["query"]]

        elif tool_name == "xm_query_nodes":
            cmd = ["./bin/xm", "--store", store_path, "--json", "query", "nodes"]
            if tool_input.get("node_type"):
                cmd.extend(["--type", tool_input["node_type"]])
            if tool_input.get("contains"):
                cmd.extend(["--contains", tool_input["contains"]])

        elif tool_name == "xm_query_backlinks":
            cmd = ["./bin/xm", "--store", store_path, "--json", "query", "backlinks",
                   tool_input["target_node"]]

        elif tool_name == "xm_node_get":
            cmd = ["./bin/xm", "--store", store_path, "--json", "node", "get",
                   tool_input["node_id"]]
        else:
            return json.dumps({"error": f"Unknown tool: {tool_name}"})

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return result.stdout[:4000]  # Truncate large outputs
        return json.dumps({"error": result.stderr[:500]})

    except Exception as e:
        return json.dumps({"error": str(e)})


def ingest_with_agent(conv: Dict, store_path: str, verbose: bool = True) -> Dict:
    """Use an LLM agent to ingest a conversation into xm."""

    conv_id = conv["sample_id"]
    sessions = conv.get("session", [])

    if verbose:
        print(f"\n{'='*60}")
        print(f"Ingesting {conv_id} with LLM agent")
        print(f"{'='*60}\n")

    # Build conversation text for agent
    conv_text = f"Conversation ID: {conv_id}\n\n"
    for session in sessions:
        session_id = session.get("session_id", "unknown")
        conv_text += f"\n--- Session {session_id} ---\n"
        for turn in session.get("turns", []):
            speaker = turn.get("speaker", "Unknown")
            content = turn.get("content", "")
            timestamp = turn.get("timestamp", "")
            conv_text += f"[{timestamp}] {speaker}: {content}\n"

    # Truncate if too long
    if len(conv_text) > 15000:
        conv_text = conv_text[:15000] + "\n... (truncated)"

    system_prompt = """You are a memory ingestion agent. Your task is to read the conversation below and store important information in the xm knowledge graph using the provided tools.

For each conversation, you should:
1. Create entity nodes for people mentioned (with name, role, relationships)
2. Create event nodes for significant events (trips, activities, achievements)
3. Create observation nodes for facts and preferences learned
4. Create links between related nodes

Focus on information that would help answer questions about:
- Who said what and when
- Important events and their timing
- Personal facts (identity, relationships, preferences)
- Temporal relationships between events

Be selective - don't store every utterance, but do capture key facts and events."""

    messages = [
        {"role": "user", "content": f"{system_prompt}\n\nConversation to ingest:\n{conv_text}\n\nPlease analyze this conversation and store the key information using the xm tools."}
    ]

    # Allow agent to make multiple tool calls
    nodes_created = 0
    links_created = 0

    for i in range(10):  # Max 10 rounds of tool calls
        response = call_claude(messages, tools=XM_TOOLS, max_tokens=2000)

        # Check if done (no more tool calls)
        stop_reason = response.get("stop_reason", "")
        content = response.get("content", [])

        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses:
            # Agent is done
            break

        # Execute tool calls
        tool_results = []
        for tool_use in tool_uses:
            tool_name = tool_use["name"]
            tool_input = tool_use["input"]

            if verbose:
                print(f"  [{i+1}] {tool_name}: {json.dumps(tool_input)[:100]}...")

            result = execute_xm_tool(tool_name, tool_input, store_path)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tool_use["id"],
                "content": result
            })

            if "node_create" in tool_name and '"ok":true' in result:
                nodes_created += 1
            if "link_create" in tool_name and '"ok":true' in result:
                links_created += 1

        # Add assistant response and tool results
        messages.append({"role": "assistant", "content": content})
        messages.append({"role": "user", "content": tool_results})

    if verbose:
        print(f"\n  Ingestion complete: {nodes_created} nodes, {links_created} links")

    return {"nodes_created": nodes_created, "links_created": links_created}


def answer_with_agent(question: str, conv_id: str, store_path: str, verbose: bool = True) -> str:
    """Use an LLM agent to query xm and answer a question."""

    system_prompt = """You are a question-answering agent with access to a knowledge graph memory system (xm).

To answer the question, you can use these tools to search the memory:
- xm_query_sparql: Execute SPARQL queries to find specific information
- xm_query_nodes: Search nodes by type or content text
- xm_query_backlinks: Find context around a specific node
- xm_node_get: Get full details of a specific node

Strategy:
1. Start by searching for relevant keywords from the question
2. If needed, follow links to find more context
3. Once you have enough information, provide your answer

Prefixes for SPARQL:
- xm: <https://xm.dev/ns/v1#>
- prov: <http://www.w3.org/ns/prov#>

If you cannot find the answer after searching, say "Cannot determine from memory"."""

    messages = [
        {"role": "user", "content": f"{system_prompt}\n\nQuestion: {question}"}
    ]

    # Allow agent to query iteratively
    for i in range(MAX_TOOL_CALLS):
        response = call_claude(messages, tools=XM_TOOLS[2:], max_tokens=1000)  # Only query tools

        content = response.get("content", [])
        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses:
            # Agent is ready to answer
            text_content = [c for c in content if c.get("type") == "text"]
            if text_content:
                return text_content[0].get("text", "Cannot determine")
            return "Cannot determine"

        # Execute queries
        tool_results = []
        for tool_use in tool_uses:
            tool_name = tool_use["name"]
            tool_input = tool_use["input"]

            if verbose:
                print(f"    Query: {tool_name} - {json.dumps(tool_input)[:80]}...")

            result = execute_xm_tool(tool_name, tool_input, store_path)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tool_use["id"],
                "content": result[:2000]  # Truncate results
            })

        messages.append({"role": "assistant", "content": content})
        messages.append({"role": "user", "content": tool_results})

    # If we exhausted tool calls, get final answer
    messages.append({"role": "user", "content": [{"type": "text", "text": "Based on what you found, please provide your final answer now."}]})
    response = call_claude(messages, max_tokens=200)
    content = response.get("content", [])
    text_content = [c for c in content if c.get("type") == "text"]
    if text_content:
        return text_content[0].get("text", "Cannot determine")
    return "Cannot determine"


def judge_answer(question: str, gold: str, generated: str) -> int:
    """Judge if answer is correct."""
    prompt = f"""You are evaluating a QA system response.

Question: {question}
Expected Answer: {gold}
Generated Answer: {generated}

Be GENEROUS - same meaning/topic counts as correct.
For dates, flexible matching is OK (May 7th = 7 May).

Respond with JSON: {{"reasoning": "brief explanation", "label": "CORRECT or WRONG"}}"""

    response = call_claude([{"role": "user", "content": prompt}], max_tokens=100)
    content = response.get("content", [])
    if content:
        text = content[0].get("text", "")
        return 1 if "CORRECT" in text.upper() else 0
    return 0


def run_agentic_benchmark(limit: int = 10, verbose: bool = True):
    """Run the agentic benchmark."""

    print(f"\n{'='*70}")
    print("  LoCoMo Agentic Benchmark")
    print(f"  Model: {MODEL}")
    print(f"{'='*70}\n")

    # Create temp store for this run
    import tempfile
    store_path = tempfile.mkdtemp(prefix="xm-agentic-")
    print(f"Store: {store_path}\n")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]
    conv_id = conv["sample_id"]

    # Phase 1: Ingest with agent
    print("Phase 1: Agentic Ingestion")
    print("-" * 40)
    ingest_stats = ingest_with_agent(conv, store_path, verbose=verbose)

    # Phase 2: Answer questions with agent
    print(f"\nPhase 2: Agentic Question Answering")
    print("-" * 40)

    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]
    results = []

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        q_display = question[:50] + "..." if len(question) > 50 else question
        print(f"\n[{i}/{len(qa_pairs)}] {q_display}")

        # Get agent's answer
        generated = answer_with_agent(question, conv_id, store_path, verbose=verbose)

        # Judge
        score = judge_answer(question, gold, generated)

        gold_display = gold[:40] + "..." if len(gold) > 40 else gold
        gen_display = generated[:40] + "..." if len(generated) > 40 else generated

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
    import shutil
    shutil.rmtree(store_path, ignore_errors=True)

    return {
        "ingest_stats": ingest_stats,
        "total": total,
        "correct": correct,
        "accuracy": accuracy
    }


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Agentic Benchmark")
    parser.add_argument("--limit", type=int, default=10, help="Max questions")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show agent queries")

    args = parser.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY not set")
        sys.exit(1)

    run_agentic_benchmark(limit=args.limit, verbose=args.verbose)


if __name__ == "__main__":
    main()
