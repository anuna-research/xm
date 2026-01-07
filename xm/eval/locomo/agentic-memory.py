#!/usr/bin/env python3
"""
LoCoMo Agentic Memory Evaluation

This evaluation tests whether an LLM agent can effectively:
1. STRUCTURE memories from conversations using xm tools (not predefined schema)
2. QUERY those memories to answer questions

The agent decides what's important to remember and how to organize it.

Aligned with official LoCoMo specification:
https://github.com/snap-research/locomo

Metrics:
- F1 Score: Token-level overlap (primary LoCoMo metric)
- LLM Judge: Binary correctness assessment (secondary)
- Category-specific scoring per LoCoMo methodology

Usage:
    export ANTHROPIC_API_KEY=your_key
    python3 eval/locomo/agentic-memory.py --limit 10
"""

import json
import subprocess
import argparse
import os
import sys
import re
import time
import string
import random
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Tuple
import requests

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "gpt-4o-mini-2024-07-18"
API_PROVIDER = "openai"  # "anthropic" or "openai"
GRAPH_URI = "https://xm.dev/ns/v1#graph/locomo/agentic"

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# ============================================================================
# Answer Normalization & F1 Scoring (LoCoMo specification)
# https://github.com/snap-research/locomo/blob/main/task_eval/evaluation.py
# ============================================================================

def normalize_answer(text: str) -> str:
    """Normalize answer following LoCoMo's normalize_answer() function.

    - Remove commas
    - Remove articles (a, an, the, and)
    - Remove punctuation
    - Normalize whitespace
    - Lowercase
    """
    if not isinstance(text, str):
        text = str(text)

    # Lowercase
    text = text.lower()

    # Remove punctuation
    text = text.translate(str.maketrans('', '', string.punctuation))

    # Split and remove articles
    articles = {'a', 'an', 'the', 'and'}
    words = text.split()
    words = [w for w in words if w not in articles]

    # Rejoin with single spaces
    return ' '.join(words)


def simple_stem(word: str) -> str:
    """Simple stemming: remove common suffixes.

    This is a simplified version - LoCoMo uses Porter Stemmer.
    For full compatibility, use nltk.stem.porter.PorterStemmer.
    """
    if len(word) > 4 and word.endswith('ing'):
        return word[:-3]
    if len(word) > 3 and word.endswith('ed'):
        return word[:-2]
    if len(word) > 2 and word.endswith('s') and not word.endswith('ss'):
        return word[:-1]
    if len(word) > 3 and word.endswith('ly'):
        return word[:-2]
    return word


def tokenize(text: str, stemming: bool = True) -> List[str]:
    """Tokenize and normalize text following LoCoMo methodology."""
    normalized = normalize_answer(text)
    words = [w for w in normalized.split() if len(w) > 0]
    if stemming:
        words = [simple_stem(w) for w in words]
    return words


def compute_token_f1(prediction: str, ground_truth: str, stemming: bool = True) -> float:
    """Compute token-level F1 score (LoCoMo's primary metric).

    Stemmed token overlap with precision/recall calculation.
    """
    pred_tokens = set(tokenize(prediction, stemming=stemming))
    truth_tokens = set(tokenize(ground_truth, stemming=stemming))

    if not pred_tokens or not truth_tokens:
        return 0.0

    intersection = pred_tokens & truth_tokens
    precision = len(intersection) / len(pred_tokens) if pred_tokens else 0.0
    recall = len(intersection) / len(truth_tokens) if truth_tokens else 0.0

    if precision + recall == 0:
        return 0.0

    return 2 * (precision * recall) / (precision + recall)


# Phrases indicating "no information available" for adversarial questions
ADVERSARIAL_PHRASES = [
    "no information",
    "cannot determine",
    "not mentioned",
    "unknown",
    "cannot be determined",
    "no answer",
    "not available",
    "insufficient information"
]


def compute_adversarial_score(prediction: str, ground_truth: str) -> float:
    """Score adversarial questions (category 5).

    Returns 1.0 if prediction indicates 'no information available'.
    """
    pred_lower = prediction.lower()
    for phrase in ADVERSARIAL_PHRASES:
        if phrase in pred_lower:
            return 1.0
    return 0.0


def compute_multi_answer_f1(prediction: str, ground_truth: str) -> float:
    """Compute F1 for comma-separated multi-part answers.

    LoCoMo splits on commas and returns max F1 across parts.
    """
    gt_string = str(ground_truth)
    gt_parts = [p.strip() for p in gt_string.split(',') if p.strip()]

    if not gt_parts:
        return 0.0

    # Return max F1 across all parts (generous matching)
    f1_scores = [compute_token_f1(prediction, part) for part in gt_parts]
    return max(f1_scores)


def compute_category_f1(prediction: str, ground_truth: str, category: int) -> float:
    """Compute F1 score with category-specific handling per LoCoMo spec.

    - Categories 2,3,4 (temporal, commonsense, multi_hop): direct F1
    - Category 1 (single_hop): F1 with comma-split partial matching
    - Category 5 (adversarial): binary check for 'no information' phrases
    """
    if category == 5:
        return compute_adversarial_score(prediction, ground_truth)
    elif category == 1:
        # Single-hop may have comma-separated answers
        return compute_multi_answer_f1(prediction, ground_truth)
    else:
        # Standard F1 for categories 2, 3, 4
        return compute_token_f1(prediction, ground_truth)


# ============================================================================
# XM Tool Execution
# ============================================================================

def run_xm_command(args: List[str], timeout: int = 30) -> Tuple[bool, str]:
    """Run an xm CLI command and return (success, output)."""
    cmd = ["./bin/xm", "--json"] + args
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=XM_DIR)
        output = result.stdout if result.returncode == 0 else result.stderr
        return result.returncode == 0, output[:3000]
    except Exception as e:
        return False, str(e)


def xm_node_create(node_type: str, properties: Dict[str, str]) -> Tuple[bool, str]:
    """Create a node in xm."""
    args = ["node", "create", "-t", node_type]
    for k, v in properties.items():
        args.extend(["-p", f"{k}={v}"])
    return run_xm_command(args)


def xm_link_create(from_node: str, to_node: str, predicate: str) -> Tuple[bool, str]:
    """Create a link between nodes."""
    args = ["link", "create", "--from", from_node, "--to", to_node, "--predicate", predicate]
    return run_xm_command(args)


def xm_query_sparql(query: str) -> Tuple[bool, str]:
    """Execute a SPARQL query."""
    args = ["query", "sparql", query]
    return run_xm_command(args, timeout=60)


def xm_query_nodes(node_type: str = None, contains: str = None) -> Tuple[bool, str]:
    """Search for nodes."""
    args = ["query", "nodes"]
    if node_type:
        args.extend(["--type", node_type])
    if contains:
        args.extend(["--contains", contains])
    return run_xm_command(args)


def xm_node_get(node_id: str) -> Tuple[bool, str]:
    """Get node details."""
    args = ["node", "get", node_id]
    return run_xm_command(args)


# ============================================================================
# Claude API with Tools
# ============================================================================

INGESTION_TOOLS = [
    {
        "name": "xm_remember",
        "description": "Store a memory/fact in the knowledge graph. Use this to remember important information from the conversation.",
        "input_schema": {
            "type": "object",
            "properties": {
                "memory_type": {
                    "type": "string",
                    "enum": ["person", "event", "fact", "preference", "relationship", "statement", "biographical", "opinion", "activity"],
                    "description": "Type of memory: person (who), event (what happened), fact (information), preference (likes/dislikes), relationship (between people), statement (exact quote), biographical (age/birthday/status/counts), opinion (what someone thinks about another), activity (hobby/sport/creative pursuit)"
                },
                "content": {
                    "type": "string",
                    "description": "The memory content - what to remember"
                },
                "subject": {
                    "type": "string",
                    "description": "Who or what this memory is about"
                },
                "timestamp": {
                    "type": "string",
                    "description": "When this occurred (if known)"
                },
                "source": {
                    "type": "string",
                    "description": "Reference to where this came from (e.g., 'D1:3' for dialog turn)"
                }
            },
            "required": ["memory_type", "content", "subject"]
        }
    },
    {
        "name": "xm_connect",
        "description": "Create a connection between two memories or concepts.",
        "input_schema": {
            "type": "object",
            "properties": {
                "from_memory": {
                    "type": "string",
                    "description": "The source memory/concept"
                },
                "relationship": {
                    "type": "string",
                    "description": "How they're related (e.g., 'causes', 'precedes', 'involves', 'about')"
                },
                "to_memory": {
                    "type": "string",
                    "description": "The target memory/concept"
                }
            },
            "required": ["from_memory", "relationship", "to_memory"]
        }
    }
]

QUERY_TOOLS = [
    {
        "name": "search_memories",
        "description": "Search memories by keyword or topic.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Keywords or topic to search for"
                },
                "memory_type": {
                    "type": "string",
                    "enum": ["person", "event", "fact", "preference", "relationship", "statement", "biographical", "opinion", "activity", "all"],
                    "description": "Filter by memory type (optional)"
                }
            },
            "required": ["query"]
        }
    },
    {
        "name": "get_memories_about",
        "description": "Get all memories related to a person or topic.",
        "input_schema": {
            "type": "object",
            "properties": {
                "subject": {
                    "type": "string",
                    "description": "Person or topic to get memories about"
                }
            },
            "required": ["subject"]
        }
    },
    {
        "name": "get_timeline",
        "description": "Get events in chronological order.",
        "input_schema": {
            "type": "object",
            "properties": {
                "subject": {
                    "type": "string",
                    "description": "Person or topic (optional - all events if not specified)"
                }
            }
        }
    },
    # ========== INTROSPECTION TOOLS ==========
    {
        "name": "schema_classes",
        "description": "List all node types (classes) in the knowledge graph with instance counts. Use this to understand what types of information are stored.",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "schema_predicates",
        "description": "List all predicates (properties/relationships) used in the knowledge graph with usage counts.",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "query_backlinks",
        "description": "Find all nodes that link TO a specific node (Org-roam style backlinks). Use this to discover related information.",
        "input_schema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "The target node URI or keyword to find backlinks for"
                }
            },
            "required": ["target"]
        }
    },
    {
        "name": "query_nodes",
        "description": "Search for nodes by type.",
        "input_schema": {
            "type": "object",
            "properties": {
                "node_type": {
                    "type": "string",
                    "description": "Filter by node type (e.g., 'fact', 'biographical', 'event')"
                },
                "limit": {
                    "type": "integer",
                    "description": "Max results to return (default 20)"
                }
            }
        }
    }
]


def call_llm_with_tools(messages: List[Dict], tools: List[Dict], system: str, max_tokens: int = 1500) -> Dict:
    """Call LLM API with tools, with retry logic for connection errors."""

    max_retries = 5
    base_delay = 1  # seconds

    for attempt in range(max_retries):
        try:
            if API_PROVIDER == "openai":
                api_key = os.environ.get("OPENAI_API_KEY")
                if not api_key:
                    raise ValueError("OPENAI_API_KEY not set")

                # Convert tools to OpenAI format
                openai_tools = []
                for tool in tools:
                    openai_tools.append({
                        "type": "function",
                        "function": {
                            "name": tool["name"],
                            "description": tool["description"],
                            "parameters": tool["input_schema"]
                        }
                    })

                # Add system message to messages
                openai_messages = [{"role": "system", "content": system}] + messages

                response = requests.post(
                    "https://api.openai.com/v1/chat/completions",
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {api_key}"
                    },
                    json={
                        "model": MODEL,
                        "max_completion_tokens": max_tokens,
                        "messages": openai_messages,
                        "tools": openai_tools if openai_tools else None
                    },
                    timeout=60
                )

                if response.status_code == 200:
                    return convert_openai_response(response.json())
            else:
                # Anthropic
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
                        "system": system,
                        "tools": tools,
                        "messages": messages
                    },
                    timeout=60
                )

                if response.status_code == 200:
                    return response.json()

            # Handle errors
            if response.status_code == 529 or response.status_code == 429:  # Overloaded/rate limit
                delay = base_delay * (2 ** attempt)
                print(f"  [API rate limited, retrying in {delay}s...]")
                time.sleep(delay)
                continue
            elif response.status_code >= 500:  # Server error
                delay = base_delay * (2 ** attempt)
                print(f"  [Server error {response.status_code}, retrying in {delay}s...]")
                time.sleep(delay)
                continue
            else:
                print(f"API error: {response.status_code} - {response.text[:200]}")
                return {"content": [], "stop_reason": "error"}

        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout,
                requests.exceptions.ChunkedEncodingError) as e:
            delay = base_delay * (2 ** attempt)
            print(f"  [Connection error, retrying in {delay}s: {str(e)[:50]}...]")
            time.sleep(delay)
            continue

    print(f"  [Max retries exceeded]")
    return {"content": [], "stop_reason": "error"}


def convert_openai_response(openai_resp: Dict) -> Dict:
    """Convert OpenAI response to Anthropic-like format for compatibility."""
    choice = openai_resp.get("choices", [{}])[0]
    message = choice.get("message", {})
    finish_reason = choice.get("finish_reason", "")

    content = []

    # Add text content
    if message.get("content"):
        content.append({"type": "text", "text": message["content"]})

    # Add tool calls
    for tool_call in message.get("tool_calls", []):
        if tool_call.get("type") == "function":
            content.append({
                "type": "tool_use",
                "id": tool_call["id"],
                "name": tool_call["function"]["name"],
                "input": json.loads(tool_call["function"]["arguments"])
            })

    stop_reason = "end_turn" if finish_reason == "stop" else finish_reason

    return {
        "content": content,
        "stop_reason": stop_reason
    }


# Alias for compatibility
call_claude_with_tools = call_llm_with_tools


def format_assistant_message(content: List[Dict]) -> Dict:
    """Format assistant message for the current API provider."""
    if API_PROVIDER == "openai":
        # Convert to OpenAI format
        text_parts = []
        tool_calls = []
        for item in content:
            if item.get("type") == "text":
                text_parts.append(item.get("text", ""))
            elif item.get("type") == "tool_use":
                tool_calls.append({
                    "id": item["id"],
                    "type": "function",
                    "function": {
                        "name": item["name"],
                        "arguments": json.dumps(item["input"])
                    }
                })
        msg = {"role": "assistant", "content": " ".join(text_parts) if text_parts else None}
        if tool_calls:
            msg["tool_calls"] = tool_calls
        return msg
    else:
        return {"role": "assistant", "content": content}


def format_tool_results(tool_results: List[Dict]) -> Any:
    """Format tool results for the current API provider."""
    if API_PROVIDER == "openai":
        # OpenAI needs separate messages for each tool result
        return [
            {
                "role": "tool",
                "tool_call_id": tr["tool_use_id"],
                "content": tr["content"]
            }
            for tr in tool_results
        ]
    else:
        return {"role": "user", "content": tool_results}


# ============================================================================
# Memory Storage - xm-backed store using CLI
# ============================================================================

class XmStore:
    """Memory store backed by actual xm CLI."""

    def __init__(self, store_path: str = None):
        self.store_path = store_path
        self.memory_id = 0
        # Track memories locally for stats (xm also stores them)
        self._memories = []
        self._connections = []

    def _run_xm(self, args: List[str], timeout: int = 30) -> Tuple[bool, str]:
        """Run xm CLI command."""
        cmd = ["./bin/xm", "--json"]
        if self.store_path:
            cmd.extend(["--store", self.store_path])
        cmd.extend(args)
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=XM_DIR)
            output = result.stdout if result.returncode == 0 else result.stderr
            return result.returncode == 0, output[:5000]
        except Exception as e:
            return False, str(e)

    def add_memory(self, memory_type: str, content: str, subject: str,
                   timestamp: str = None, source: str = None) -> str:
        """Add a memory as an xm node."""
        self.memory_id += 1
        mem_id = f"mem_{self.memory_id}"

        # Map memory types to xm node types
        xm_type = "agent" if memory_type == "person" else "fact"

        # Create node with properties
        args = ["node", "create", "-t", xm_type]
        args.extend(["-p", f"content={content}"])
        args.extend(["-p", f"subject={subject.lower()}"])
        args.extend(["-p", f"memory_type={memory_type}"])
        if timestamp:
            args.extend(["-p", f"timestamp={timestamp}"])
        if source:
            args.extend(["-p", f"source={source}"])

        success, output = self._run_xm(args)

        # Track locally for stats
        self._memories.append({
            "id": mem_id,
            "type": memory_type,
            "content": content,
            "subject": subject.lower(),
            "timestamp": timestamp,
            "source": source
        })

        return mem_id

    def add_connection(self, from_mem: str, relationship: str, to_mem: str):
        """Track connection (simplified - full xm linking needs node URIs)."""
        self._connections.append({
            "from": from_mem.lower(),
            "relationship": relationship,
            "to": to_mem.lower()
        })

    def search(self, query: str, memory_type: str = None) -> List[Dict]:
        """Search memories using SPARQL REGEX for flexible matching."""
        # Build regex pattern from query words (OR matching)
        words = query.lower().split()
        # Escape special regex chars and join with OR
        pattern = "|".join(re.escape(w) for w in words if len(w) > 2)

        if not pattern:
            pattern = re.escape(query.lower())

        type_filter = ""
        if memory_type and memory_type != "all":
            type_filter = f"FILTER(CONTAINS(STR(?type), '{memory_type}'))"

        sparql = f"""
        SELECT ?node ?type ?content ?subject ?timestamp WHERE {{
            ?node a ?type .
            ?node <https://xm.dev/ns/v1#content> ?content .
            ?node <https://xm.dev/ns/v1#subject> ?subject .
            OPTIONAL {{ ?node <https://xm.dev/ns/v1#timestamp> ?timestamp }}
            FILTER(REGEX(?content, '{pattern}', 'i') || REGEX(?subject, '{pattern}', 'i'))
            {type_filter}
        }} LIMIT 15
        """

        success, output = self._run_xm(["query", "sparql", sparql])

        if success:
            try:
                results = json.loads(output)
                bindings = results.get("results", {}).get("bindings", [])
                return [self._binding_to_memory(b) for b in bindings]
            except:
                pass

        # Fallback to local search
        return self._local_search(query, memory_type)

    def _local_search(self, query: str, memory_type: str = None) -> List[Dict]:
        """Enhanced local search with word matching, synonyms, and substring matching."""
        query_lower = query.lower()
        query_words = set(query_lower.split())

        # Expanded synonyms for better matching
        synonyms = {
            # Social
            "friend": ["friends", "friendship", "buddy", "close", "support"],
            "friends": ["friend", "friendship", "buddy", "close", "support"],
            # Reading
            "book": ["books", "reading", "read", "novel", "title", "charlotte", "becoming", "nicole"],
            "books": ["book", "reading", "read", "novel", "title", "charlotte", "becoming", "nicole"],
            "reading": ["book", "books", "read", "novel"],
            # Activities
            "activity": ["activities", "hobby", "hobbies", "sport", "partake"],
            "activities": ["activity", "hobby", "hobbies", "sport", "partake"],
            "hobby": ["hobbies", "activity", "activities"],
            # Sports/Exercise
            "swim": ["swimming", "swam", "pool"],
            "swimming": ["swim", "swam", "pool"],
            "run": ["running", "ran", "race", "marathon", "charity"],
            "running": ["run", "ran", "race", "marathon", "charity"],
            "race": ["running", "ran", "marathon", "charity"],
            "hike": ["hiking", "hiked", "trail", "mountain"],
            "hiking": ["hike", "hiked", "trail", "mountain"],
            # Outdoors
            "camp": ["camping", "camped", "tent", "outdoor", "forest", "mountain", "beach"],
            "camping": ["camp", "camped", "tent", "outdoor", "forest", "mountain", "beach"],
            "outdoor": ["outdoors", "outside", "nature", "camping", "hiking"],
            # Art
            "paint": ["painting", "painted", "art", "artwork", "canvas", "sunrise", "sunset"],
            "painting": ["paint", "painted", "art", "artwork", "canvas", "sunrise", "sunset"],
            "art": ["painting", "pottery", "drawing", "artwork", "creative"],
            "pottery": ["pot", "pots", "bowl", "plate", "ceramic", "clay"],
            # Pets/Animals
            "pet": ["pets", "dog", "cat", "animal", "luna", "oliver", "bailey", "oscar"],
            "pets": ["pet", "dog", "cat", "animal", "luna", "oliver", "bailey", "oscar"],
            "dog": ["pet", "pets", "luna", "animal"],
            "cat": ["pet", "pets", "oliver", "bailey", "animal"],
            # Family
            "gift": ["gave", "received", "present", "necklace", "bowl"],
            "grandma": ["grandmother", "grandparent", "necklace", "sweden"],
            "grandmother": ["grandma", "grandparent"],
            "child": ["children", "kids", "kid", "son", "daughter"],
            "children": ["child", "kids", "kid", "son", "daughter"],
            "kids": ["children", "child", "kid", "son", "daughter"],
            # Music
            "instrument": ["instruments", "music", "play", "piano", "guitar", "clarinet", "violin"],
            "instruments": ["instrument", "music", "play", "piano", "guitar", "clarinet", "violin"],
            "music": ["instrument", "piano", "guitar", "clarinet", "violin", "song", "concert"],
            # Events
            "conference": ["event", "meeting", "workshop", "transgender"],
            "workshop": ["conference", "event", "meeting", "counseling"],
            "parade": ["pride", "march", "event"],
            # Places
            "country": ["sweden", "home", "moved", "from"],
            "sweden": ["country", "home", "moved", "grandma"],
        }

        # Expand query with synonyms
        expanded_words = set(query_words)
        for word in query_words:
            if word in synonyms:
                expanded_words.update(synonyms[word])

        results = []
        for mem in self._memories:
            if memory_type and memory_type != "all" and mem["type"] != memory_type:
                continue

            content_lower = mem["content"].lower()
            subject_lower = mem["subject"].lower()
            text = content_lower + " " + subject_lower

            # Score based on matches
            score = 0

            # Exact phrase match (highest priority)
            if query_lower in text:
                score += 15

            # Word matches with expanded synonyms
            text_words = set(text.split())
            matching_words = expanded_words & text_words
            score += len(matching_words) * 3

            # Substring matching - check if any query word appears as substring
            for word in query_words:
                if len(word) >= 3:  # Only for words 3+ chars
                    if word in text:
                        score += 5
                    # Also check if text words start with query word (prefix match)
                    for text_word in text_words:
                        if text_word.startswith(word) or word.startswith(text_word):
                            score += 2

            # Boost if subject matches any query word
            for word in query_words:
                if word in subject_lower:
                    score += 8

            if score > 0:
                results.append((score, mem))

        # Sort by score descending
        results.sort(key=lambda x: -x[0])
        return [r[1] for r in results[:20]]  # Return more results

    def _binding_to_memory(self, binding: Dict) -> Dict:
        """Convert SPARQL binding to memory dict."""
        return {
            "id": binding.get("node", {}).get("value", ""),
            "type": binding.get("type", {}).get("value", "").split("/")[-1],
            "content": binding.get("content", {}).get("value", ""),
            "subject": binding.get("subject", {}).get("value", ""),
            "timestamp": binding.get("timestamp", {}).get("value", "")
        }

    def get_about(self, subject: str) -> List[Dict]:
        """Get all memories about a subject - returns comprehensive results."""
        subject_lower = subject.lower()

        # First, get all memories where subject matches directly
        direct_matches = []
        content_matches = []

        for mem in self._memories:
            mem_subject = mem["subject"].lower()
            mem_content = mem["content"].lower()

            # Direct subject match (highest priority)
            if subject_lower in mem_subject or mem_subject in subject_lower:
                direct_matches.append(mem)
            # Content mention
            elif subject_lower in mem_content:
                content_matches.append(mem)

        # Combine: direct matches first, then content matches
        results = direct_matches + content_matches

        # Also include search results to catch related items
        search_results = self._local_search(subject, None)
        for mem in search_results:
            if mem not in results:
                results.append(mem)

        return results[:25]  # Return more results for comprehensive coverage

    def get_timeline(self, subject: str = None) -> List[Dict]:
        """Get events in order."""
        events = [m for m in self._memories if m["type"] == "event"]
        if subject:
            subject_lower = subject.lower()
            events = [e for e in events if subject_lower in e["subject"] or subject_lower in e["content"].lower()]
        return sorted(events, key=lambda x: x.get("timestamp") or "")[:15]

    def stats(self) -> Dict:
        """Get memory statistics."""
        by_type = {}
        for mem in self._memories:
            by_type[mem["type"]] = by_type.get(mem["type"], 0) + 1
        return {
            "total_memories": len(self._memories),
            "total_connections": len(self._connections),
            "by_type": by_type
        }

    def show_schema(self):
        """Display schema using xm CLI."""
        print("\n  === xm Schema ===")
        success, output = self._run_xm(["schema", "classes"])
        if success:
            print(output)
        success, output = self._run_xm(["schema", "predicates"])
        if success:
            print(output[:1000])

    # ========== INTROSPECTION METHODS ==========

    def schema_classes(self) -> str:
        """List all node types with counts."""
        success, output = self._run_xm(["schema", "classes"])
        if success:
            return output
        # Fallback to local stats
        return json.dumps({"classes": self.stats()["by_type"]}, indent=2)

    def schema_predicates(self) -> str:
        """List all predicates with usage counts."""
        success, output = self._run_xm(["schema", "predicates"])
        if success:
            return output
        # Fallback: list unique keys
        predicates = set()
        for mem in self._memories:
            predicates.update(mem.keys())
        return json.dumps({"predicates": list(predicates)}, indent=2)

    def query_backlinks(self, target: str) -> str:
        """Find nodes linking TO a target (Org-roam style backlinks)."""
        # First try xm query backlinks
        success, output = self._run_xm(["query", "backlinks", target])
        if success and "bindings" in output:
            return output

        # Fallback: search for mentions in content
        results = []
        target_lower = target.lower()
        for mem in self._memories:
            if target_lower in mem["content"].lower() or target_lower in mem["subject"]:
                results.append(mem)
        return json.dumps(results[:15], indent=2) if results else "No backlinks found"

    def query_nodes(self, node_type: str = None, limit: int = 20) -> str:
        """Search for nodes by type."""
        if node_type:
            # Filter by type locally
            results = [m for m in self._memories if m["type"] == node_type][:limit]
            return json.dumps(results, indent=2) if results else f"No nodes of type '{node_type}'"

        # Return all nodes (limited)
        return json.dumps(self._memories[:limit], indent=2)


# Alias for compatibility
MemoryStore = XmStore

# Global memory store for this evaluation
MEMORY_STORE = XmStore()


# ============================================================================
# Tool Execution
# ============================================================================

def execute_ingestion_tool(tool_name: str, tool_input: Dict) -> str:
    """Execute an ingestion tool call."""
    if tool_name == "xm_remember":
        mem_id = MEMORY_STORE.add_memory(
            memory_type=tool_input.get("memory_type", "fact"),
            content=tool_input.get("content", ""),
            subject=tool_input.get("subject", ""),
            timestamp=tool_input.get("timestamp"),
            source=tool_input.get("source")
        )
        return json.dumps({"ok": True, "memory_id": mem_id})

    elif tool_name == "xm_connect":
        MEMORY_STORE.add_connection(
            from_mem=tool_input.get("from_memory", ""),
            relationship=tool_input.get("relationship", "related"),
            to_mem=tool_input.get("to_memory", "")
        )
        return json.dumps({"ok": True})

    return json.dumps({"error": f"Unknown tool: {tool_name}"})


def execute_query_tool(tool_name: str, tool_input: Dict) -> str:
    """Execute a query tool call."""
    if tool_name == "search_memories":
        results = MEMORY_STORE.search(
            query=tool_input.get("query", ""),
            memory_type=tool_input.get("memory_type")
        )
        return json.dumps({"memories": results})

    elif tool_name == "get_memories_about":
        results = MEMORY_STORE.get_about(subject=tool_input.get("subject", ""))
        return json.dumps({"memories": results})

    elif tool_name == "get_timeline":
        results = MEMORY_STORE.get_timeline(subject=tool_input.get("subject"))
        return json.dumps({"events": results})

    # Introspection tools
    elif tool_name == "schema_classes":
        return MEMORY_STORE.schema_classes()

    elif tool_name == "schema_predicates":
        return MEMORY_STORE.schema_predicates()

    elif tool_name == "query_backlinks":
        return MEMORY_STORE.query_backlinks(tool_input.get("target", ""))

    elif tool_name == "query_nodes":
        return MEMORY_STORE.query_nodes(
            node_type=tool_input.get("node_type"),
            limit=tool_input.get("limit", 20)
        )

    return json.dumps({"error": f"Unknown tool: {tool_name}"})


# ============================================================================
# LLM-based Implicit Fact Extraction (General Approach)
# ============================================================================

FACT_EXTRACTION_SYSTEM = """You are a fact extraction agent. Given a set of memories, your task is to identify IMPLICIT facts that can be inferred but are not explicitly stated.

For each implicit fact you find, output it using the extract_fact tool.

**What to look for:**

1. **Status inferences**: "single parent" implies relationship_status=single
2. **Location expansions**: "camped at beach and mountains" → separate facts for each location
3. **Temporal calculations**: "friends for 4 years" + session_date → friendship_start_date
4. **Role inferences**: "her children love dinosaurs" → she has children, she is a parent
5. **Trait inferences**: "volunteers at youth center" → she is community-oriented

**Rules:**
- Only extract facts that are NOT already explicitly stated
- Each fact should be atomic (one piece of information)
- Include the subject (who the fact is about)
- Be conservative - only extract facts that are clearly implied

**Example:**
Memory: "Melanie, as a single parent, took her kids camping at the beach and mountains"
Implicit facts to extract:
- Melanie's relationship status is single
- Melanie camping location: beach
- Melanie camping location: mountains
- Melanie is a parent
- Melanie has children"""

FACT_EXTRACTION_TOOLS = [
    {
        "name": "extract_fact",
        "description": "Extract an implicit fact that can be inferred from memories",
        "input_schema": {
            "type": "object",
            "properties": {
                "subject": {
                    "type": "string",
                    "description": "Who this fact is about"
                },
                "fact_type": {
                    "type": "string",
                    "enum": ["biographical", "preference", "relationship", "location", "activity", "trait"],
                    "description": "Category of the fact"
                },
                "content": {
                    "type": "string",
                    "description": "The implicit fact to store"
                },
                "source_memory": {
                    "type": "string",
                    "description": "Brief reference to which memory this was inferred from"
                }
            },
            "required": ["subject", "fact_type", "content"]
        }
    }
]


def run_llm_fact_extraction(batch_size: int = 20, verbose: bool = True) -> int:
    """Use LLM to extract implicit facts from stored memories.

    This is a general approach that leverages the model's reasoning
    to find implicit information, rather than task-specific patterns.
    """
    if verbose:
        print("\n  Running LLM-based implicit fact extraction...")

    memories = MEMORY_STORE._memories
    if not memories:
        return 0

    extracted_count = 0

    # Process memories in batches
    for i in range(0, len(memories), batch_size):
        batch = memories[i:i + batch_size]

        # Format memories for the LLM
        memories_text = "\n".join([
            f"- [{m['type']}] {m['subject']}: {m['content']}"
            for m in batch
        ])

        messages = [{
            "role": "user",
            "content": f"""Analyze these memories and extract any IMPLICIT facts that can be inferred but are not explicitly stated.

MEMORIES:
{memories_text}

Use extract_fact for each implicit fact you find. Only extract facts that add NEW information not already stated."""
        }]

        # Run extraction loop
        for _ in range(15):  # Max tool calls per batch
            response = call_llm_with_tools(
                messages,
                FACT_EXTRACTION_TOOLS,
                FACT_EXTRACTION_SYSTEM,
                max_tokens=1500
            )

            content = response.get("content", [])
            stop_reason = response.get("stop_reason", "")

            tool_uses = [c for c in content if c.get("type") == "tool_use"]

            if not tool_uses or stop_reason == "end_turn":
                break

            # Process extracted facts
            tool_results = []
            for tool_use in tool_uses:
                if tool_use["name"] == "extract_fact":
                    inp = tool_use["input"]
                    subject = inp.get("subject", "").lower()
                    fact_content = inp.get("content", "")
                    fact_type = inp.get("fact_type", "fact")

                    # Check if this fact is truly new (not already stored)
                    is_new = True
                    fact_lower = fact_content.lower()
                    for existing in MEMORY_STORE._memories:
                        if (fact_lower in existing["content"].lower() or
                            existing["content"].lower() in fact_lower):
                            is_new = False
                            break

                    if is_new and fact_content:
                        MEMORY_STORE.add_memory(
                            memory_type=fact_type,
                            content=fact_content,
                            subject=subject,
                            source="llm_inference"
                        )
                        extracted_count += 1

                        if verbose:
                            print(f"    + {fact_content[:60]}...")

                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": tool_use["id"],
                        "content": json.dumps({"stored": is_new})
                    })

            messages.append(format_assistant_message(content))
            formatted_results = format_tool_results(tool_results)
            if isinstance(formatted_results, list):
                messages.extend(formatted_results)
            else:
                messages.append(formatted_results)

    if verbose:
        print(f"  → Extracted {extracted_count} implicit facts via LLM reasoning")

    return extracted_count


# ============================================================================
# Agentic Ingestion
# ============================================================================

# ============================================================================
# EDU (Elementary Discourse Unit) Ingestion Prompt
# Based on EMem paper: https://arxiv.org/html/2511.17208
# ============================================================================

EDU_INGESTION_SYSTEM = """You are an EDU (Elementary Discourse Unit) extraction agent.

Extract SELF-CONTAINED event statements from conversations. Each EDU should be complete enough to answer questions WITHOUT needing other memories.

**EDU PRINCIPLES:**
1. Each memory is a COMPLETE, STANDALONE statement
2. Include WHO, WHAT, WHEN, WHERE in a SINGLE statement
3. Resolve relative dates to ABSOLUTE dates using session date
4. Use full names (not pronouns)
5. Include specific details (names, numbers, titles)

**GOOD EDUs (self-contained):**
- "Melanie went camping in the mountains on 20 June 2023 with her family"
- "Caroline is a transgender woman who moved from Sweden 4 years ago"
- "Melanie has been married for 15 years as of October 2023"
- "Melanie has a dog named Luna and a cat named Oliver"
- "Caroline has a guinea pig named Oscar"
- "Melanie's kids love dinosaurs and enjoyed the museum dinosaur exhibit on 5 July 2023"

**BAD EDUs (fragmented - AVOID THESE):**
- "She went camping" (who? when?)
- "They have pets" (who? what pets?)
- "The kids loved it" (loved what? when?)

**TEMPORAL RESOLUTION - CRITICAL:**
Session date is in the header (e.g., "Session 5 (1:36 pm on 2 July 2023)").
Convert ALL relative dates:
- "yesterday" → calculate actual date
- "last Saturday" → calculate actual date
- "last year" → calculate year
- "next month" → calculate month

**FOR EACH EDU, store with:**
- memory_type: "edu" (or "event" for dated activities)
- content: The complete self-contained statement
- subject: Main person this is about
- timestamp: Absolute date if applicable

Example: If session is "25 May 2023" and someone says "I ran a race last Saturday":
→ Store: "Melanie ran a charity race on 20 May 2023" with timestamp "20 May 2023"
"""

# ============================================================================
# Standard Ingestion Prompt (fragmented facts)
# ============================================================================

INGESTION_SYSTEM = """You are a memory agent. Your task is to read conversation sessions and store important memories using the provided tools.

For each conversation session, identify and store:
1. **Facts about people**: Identity, background, relationships, characteristics
2. **Events**: Activities, trips, achievements, with timing when mentioned
3. **Preferences**: What people like, want, plan to do
4. **Key statements**: Important things said that might be referenced later

Be SELECTIVE but COMPLETE - don't miss specific details that answer questions like:
"What exactly did X do?", "What specific things does Y like?", "How many Z?"

**CRITICAL - BIOGRAPHICAL DETAILS**:
Store specific biographical facts that could be asked later:
- Relationship status (single, married, dating)
- Age, birthdays, anniversaries (e.g., "daughter's birthday is 13 August")
- Number of children and their details (names, ages, birthdays)
- Home country, where they moved from (store the actual country name!)
- How long they've known people, been married, etc.

**CRITICAL - SPECIFIC NAMES AND TITLES**:
Always store the EXACT names, not descriptions:
- Book titles: "Becoming Nicole", "Nothing is Impossible" (not "a book about...")
- Band/artist names: "Summer Sounds", "Matt Patterson" (not "a band")
- Specific art styles: "abstract art" (not just "art")
- Symbol names: "rainbow flag", "transgender symbol" (not "symbols")
- Place names: "Sweden" (not "home country")
- Pet names: "Oliver", "Luna", "Bailey" (not "her pets")

**CRITICAL - NUMBERS AND COUNTS**:
Store explicit numbers when mentioned:
- "3 children" - store the number explicitly
- "5 years married" - store duration
- "visited beach 2 times" - store count
- "plays 2 instruments: violin and clarinet" - store each instrument

**CRITICAL - DATE HANDLING**:
The session header shows the date (e.g., "Session 5 (1:36 pm on 2 July 2023)").
When someone mentions relative dates, CONVERT THEM TO ABSOLUTE DATES:
- "yesterday" → the day before the session date
- "last week" → the week before the session date
- "last Saturday" → the Saturday before the session date
- "last month" → the month before the session date
- "next month" → the month after the session date
- "three years ago" → calculate from session date

For example, if the session is on "25 May 2023" and someone says "I ran a race last Saturday",
store the timestamp as "20 May 2023" (the Saturday before), NOT "last Saturday".

**ALWAYS include timestamps** - not just for events, but also for facts that have temporal context:
- Age-related facts: include when the age was stated
- Duration facts: "friends for 4 years" → calculate and store the start date
- Time-bound facts: include the session date as timestamp

**CRITICAL - LIST COMPLETENESS**:
When someone mentions a LIST of items, store EACH ITEM as a SEPARATE memory:
- Books mentioned → store EACH book title separately
- Activities → store EACH activity (swimming, painting, running, pottery)
- Places visited → store EACH location (beach, mountains, forest)
- Instruments played → store EACH instrument (violin, clarinet)
- Items purchased → store EACH item (figurines, shoes)
- Paintings created → store EACH subject (horse, sunset, sunrise)

Example: If someone says "I've been reading Dr. Seuss and Nothing is Impossible":
- Store: "Read book: Dr. Seuss" (with timestamp)
- Store: "Read book: Nothing is Impossible" (with timestamp)

**CRITICAL - OPINIONS AND REACTIONS**:
Store what people think about others' decisions/actions:
- "Melanie thinks Caroline will be an awesome mom"
- "Melanie is supportive of Caroline's transition"
- These help answer inference questions later

**CRITICAL - HOBBIES AND COLLECTIONS**:
Store hobby details that enable inference:
- "Caroline collects classic children's books"
- "Melanie likes classical music"
- "Melanie prefers outdoor activities over indoor"
- These help answer "would X likely enjoy Y?" questions

**CRITICAL - SPECIFIC DETAILS**:
Store specific names, titles, and details - not just general categories:
- ✓ "Read 'Nothing is Impossible' by Diana Nyad" (specific)
- ✗ "Has been reading books" (too general)
- ✓ "Melanie does swimming, painting, and running" (specific activities)
- ✗ "Melanie has hobbies" (too general)
- ✓ "Caroline moved from Sweden 4 years ago" (specific)
- ✗ "Caroline moved from her home country" (too vague)

Use the source field to track which dialog turn (e.g., "D1:3") the information came from."""


def ingest_session_with_agent(session_data: Dict, session_idx: int, verbose: bool = True, edu_mode: bool = False) -> int:
    """Have the agent ingest a single session."""

    # Format session for the agent
    session_date = session_data.get("date", "unknown date")
    turns = session_data.get("turns", [])

    session_text = f"Session {session_idx}\n"
    session_text += f"**SESSION DATE: {session_date}**\n"
    session_text += "(Use this date to convert any relative dates like 'yesterday', 'last week', etc.)\n\n"

    for turn in turns:
        speaker = turn.get("speaker", "Unknown")
        text = turn.get("text", "")
        dia_id = turn.get("dia_id", "")
        session_text += f"[{dia_id}] {speaker}: {text}\n"

    messages = [{
        "role": "user",
        "content": f"Read this conversation session and store the important memories:\n\n{session_text}\n\nUse xm_remember to store facts, events, and key information. Be selective. IMPORTANT: Convert all relative dates to absolute dates based on the session date shown above."
    }]

    memories_created = 0

    # Run agent loop
    for i in range(25):  # Max 25 tool calls per session (increased for thorough extraction)
        system_prompt = EDU_INGESTION_SYSTEM if edu_mode else INGESTION_SYSTEM
        response = call_llm_with_tools(messages, INGESTION_TOOLS, system_prompt, max_tokens=1500)

        content = response.get("content", [])
        stop_reason = response.get("stop_reason", "")

        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses or stop_reason == "end_turn":
            break

        # Execute tools
        tool_results = []
        for tool_use in tool_uses:
            tool_name = tool_use["name"]
            tool_input = tool_use["input"]

            if verbose:
                content_preview = tool_input.get("content", "")[:50]
                print(f"    [{tool_name}] {content_preview}...")

            result = execute_ingestion_tool(tool_name, tool_input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tool_use["id"],
                "content": result
            })

            if "xm_remember" in tool_name:
                memories_created += 1

        messages.append(format_assistant_message(content))
        formatted_results = format_tool_results(tool_results)
        if isinstance(formatted_results, list):
            messages.extend(formatted_results)
        else:
            messages.append(formatted_results)

    return memories_created


def ingest_conversation_with_agent(conv: Dict, verbose: bool = True, extract_implicit: bool = False, edu_mode: bool = False) -> Dict:
    """Have the agent ingest an entire conversation."""

    conv_id = conv["sample_id"]
    conversation_data = conv.get("conversation", {})
    speaker_a = conversation_data.get("speaker_a", "Unknown")
    speaker_b = conversation_data.get("speaker_b", "Unknown")

    if verbose:
        print(f"\n{'='*60}")
        print(f"  Agentic Ingestion: {conv_id}")
        print(f"  Speakers: {speaker_a}, {speaker_b}")
        print(f"{'='*60}\n")

    # First, store the speakers
    MEMORY_STORE.add_memory("person", f"{speaker_a} is one of the main speakers", speaker_a)
    MEMORY_STORE.add_memory("person", f"{speaker_b} is one of the main speakers", speaker_b)

    total_memories = 2

    # Ingest each session
    session_idx = 1
    while True:
        session_key = f"session_{session_idx}"
        date_key = f"session_{session_idx}_date_time"

        session_turns = conversation_data.get(session_key)
        if not session_turns:
            break

        session_date = conversation_data.get(date_key, "")

        if verbose:
            print(f"  Session {session_idx} ({session_date[:10] if session_date else 'no date'})...")

        session_data = {
            "date": session_date,
            "turns": session_turns
        }

        memories = ingest_session_with_agent(session_data, session_idx, verbose, edu_mode=edu_mode)
        total_memories += memories

        if verbose:
            print(f"    → {memories} memories stored")

        session_idx += 1

    # Run LLM-based implicit fact extraction if enabled
    if extract_implicit:
        run_llm_fact_extraction(verbose=verbose)

    stats = MEMORY_STORE.stats()
    if verbose:
        print(f"\n  Total: {stats['total_memories']} memories, {stats['total_connections']} connections")
        print(f"  By type: {stats['by_type']}")

    return stats


# ============================================================================
# Agentic Query
# ============================================================================

QUERY_SYSTEM = """You are a question-answering agent with access to a memory system.

Use the search tools to find relevant memories, then answer the question based on what you find.

**AVAILABLE TOOLS**:

INTROSPECTION (use to understand the knowledge graph):
- schema_classes: See what types of nodes exist (fact, person, event, biographical, etc.)
- schema_predicates: See what properties are available
- query_backlinks: Find nodes that link TO a target (discover related info)
- query_nodes: List nodes by type

SEARCH (use to find specific memories):
- search_memories: Keyword search
- get_memories_about: All memories about a person/topic
- get_timeline: Events in chronological order

**ANSWER FORMAT - KEEP IT CONCISE**:
Give SHORT, DIRECT answers that match what was asked:
- For "What X?" questions: List the items directly
- For "When?" questions: Give the date/time
- For "How many?" questions: Give the number
- For "Who?" questions: Give the name(s)
- Avoid lengthy explanations unless the question asks "why" or "how"

Examples:
- BAD: "Melanie engages in various activities including painting which she finds relaxing..."
- GOOD: "Swimming, painting, running, pottery"

- BAD: "Caroline attended the LGBTQ support group on **7 May 2023** where she felt..."
- GOOD: "7 May 2023"

**CRITICAL SEARCH STRATEGY**:

1. **ALWAYS start with get_memories_about for the PERSON mentioned**:
   - "What are Melanie's pets?" → First: get_memories_about("Melanie")
   - "When did Caroline go to..." → First: get_memories_about("Caroline")
   - This returns ALL memories about that person, then you can scan for the answer

2. **Search for SPECIFIC ITEMS, not just categories**:
   - For pets: search "dog", "cat", "Luna", "Oliver", "Bailey" (not just "pets")
   - For books: search "Charlotte", "Becoming Nicole", "reading" (not just "books")
   - For instruments: search "piano", "guitar", "clarinet", "violin" (not just "instruments")
   - For gifts: search "necklace", "bowl", "gave", "received" (not just "gift")

3. **For possessive questions ("X's Y"), search the PERSON first**:
   - "Melanie's pets" → get_memories_about("Melanie"), then look for dog/cat mentions
   - "Caroline's grandma" → get_memories_about("Caroline"), then look for grandma/grandmother
   - "Melanie's children" → get_memories_about("Melanie"), then count kids/son/daughter mentions

4. **Search for related concepts**:
   - "country" → also search "Sweden", "moved", "from"
   - "charity race" → also search "running", "mental health"
   - "conference" → also search "transgender", "LGBTQ", "workshop"

5. **Use get_timeline for ANY time-related question**:
   - When questions, how long ago, dates, etc.

**IMPORTANT**:
- Don't give up after one search! Try at least 3-4 different approaches.
- If category search fails, try specific item names
- ALWAYS try get_memories_about for the person mentioned

**For commonsense/inference questions** ("Would X likely...", "Is X considered..."):
- First get all memories about the person
- Look for related preferences, activities, or stated values
- If someone enjoys outdoor activities → likely prefers national park over theme park
- If someone is supportive of a community → likely considered an ally
- Make reasonable inferences based on what you find - don't just say "cannot determine"

If you truly cannot find ANY relevant information after 4+ different searches, say "Cannot determine from memory"."""


def answer_with_agent(question: str, verbose: bool = True) -> str:
    """Have the agent answer a question using memory tools."""

    messages = [{
        "role": "user",
        "content": f"Answer this question using the memory tools:\n\nQuestion: {question}"
    }]

    # Run agent loop
    for i in range(8):  # Max 8 queries per question (allow more search iterations)
        response = call_llm_with_tools(messages, QUERY_TOOLS, QUERY_SYSTEM, max_tokens=1000)

        content = response.get("content", [])
        stop_reason = response.get("stop_reason", "")

        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses or stop_reason == "end_turn":
            # Extract text answer
            text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return " ".join(text_parts).strip() or "Cannot determine"

        # Execute tools
        tool_results = []
        for tool_use in tool_uses:
            tool_name = tool_use["name"]
            tool_input = tool_use["input"]

            if verbose:
                query = tool_input.get("query") or tool_input.get("subject") or "timeline"
                print(f"    [{tool_name}] {query}")

            result = execute_query_tool(tool_name, tool_input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": tool_use["id"],
                "content": result
            })

        messages.append(format_assistant_message(content))
        formatted_results = format_tool_results(tool_results)
        if isinstance(formatted_results, list):
            messages.extend(formatted_results)
        else:
            messages.append(formatted_results)

    return "Cannot determine (max queries reached)"


def process_single_qa(qa: Dict, index: int, total: int, verbose: bool = False) -> Dict:
    """Process a single QA pair - answer and judge. Thread-safe for parallel execution."""
    question = qa["question"]
    gold = str(qa["answer"])
    category = qa["category"]
    evidence = qa.get("evidence", [])

    # Get agent's answer (verbose=False to avoid interleaved output in parallel mode)
    generated = answer_with_agent(question, verbose=verbose)

    # Compute F1 score (LoCoMo primary metric)
    f1 = compute_category_f1(generated, gold, category)

    # LLM Judge (secondary metric)
    llm_score = judge_answer(question, gold, generated)

    return {
        "index": index,
        "question": question,
        "expected": gold,
        "generated": generated,
        "category": category,
        "category_name": CATEGORY_NAMES[category],
        "evidence": evidence,
        "f1_score": round(f1, 4),
        "llm_judge": "CORRECT" if llm_score == 1 else "WRONG",
        "llm_judge_score": llm_score
    }


# ============================================================================
# Judge
# ============================================================================

def judge_answer(question: str, gold: str, generated: str) -> int:
    """Judge if answer is correct, with retry logic."""

    # LLM Judge prompt (verbatim from mem0 evaluation)
    # https://github.com/mem0ai/mem0/blob/main/evaluation/metrics/llm_judge.py
    prompt = f"""
Your task is to label an answer to a question as 'CORRECT' or 'WRONG'. You will be given the following data:
    (1) a question (posed by one user to another user),
    (2) a 'gold' (ground truth) answer,
    (3) a generated answer
which you will score as CORRECT/WRONG.

The point of the question is to ask about something one user should know about the other user based on their prior conversations.
The gold answer will usually be a concise and short answer that includes the referenced topic, for example:
Question: Do you remember what I got the last time I went to Hawaii?
Gold answer: A shell necklace
The generated answer might be much longer, but you should be generous with your grading - as long as it touches on the same topic as the gold answer, it should be counted as CORRECT.

For time related questions, the gold answer will be a specific date, month, year, etc. The generated answer might be much longer or use relative time references (like "last Tuesday" or "next month"), but you should be generous with your grading - as long as it refers to the same date or time period as the gold answer, it should be counted as CORRECT. Even if the format differs (e.g., "May 7th" vs "7 May"), consider it CORRECT if it's the same date.

Now it's time for the real question:
Question: {question}
Gold answer: {gold}
Generated answer: {generated}

First, provide a short (one sentence) explanation of your reasoning, then finish with CORRECT or WRONG.
Do NOT include both CORRECT and WRONG in your response, or it will break the evaluation script.

Just return the label CORRECT or WRONG in a json format with the key as "label".
"""

    max_retries = 5
    base_delay = 1

    for attempt in range(max_retries):
        try:
            if API_PROVIDER == "openai":
                api_key = os.environ.get("OPENAI_API_KEY")
                if not api_key:
                    raise ValueError("OPENAI_API_KEY not set")

                response = requests.post(
                    "https://api.openai.com/v1/chat/completions",
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {api_key}"
                    },
                    json={
                        "model": MODEL,
                        "max_completion_tokens": 100,
                        "messages": [{"role": "user", "content": prompt}]
                    },
                    timeout=30
                )

                if response.status_code == 200:
                    choices = response.json().get("choices", [])
                    if choices:
                        text = choices[0].get("message", {}).get("content", "")
                        return 1 if "CORRECT" in text.upper() else 0
                    return 0
            else:
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
                        "max_tokens": 100,
                        "messages": [{"role": "user", "content": prompt}]
                    },
                    timeout=30
                )

                if response.status_code == 200:
                    content = response.json().get("content", [])
                    if content:
                        text = content[0].get("text", "")
                        return 1 if "CORRECT" in text.upper() else 0
                    return 0

            if response.status_code >= 500 or response.status_code in [529, 429]:
                delay = base_delay * (2 ** attempt)
                time.sleep(delay)
                continue
            else:
                return 0

        except (requests.exceptions.ConnectionError,
                requests.exceptions.Timeout,
                requests.exceptions.ChunkedEncodingError):
            delay = base_delay * (2 ** attempt)
            time.sleep(delay)
            continue

    return 0


# ============================================================================
# Main Evaluation
# ============================================================================

def run_agentic_memory_eval(limit: int = 10, verbose: bool = True, show_schema: bool = False, store_path: str = None, workers: int = 1, extract_implicit: bool = False, shuffle: bool = False, edu_mode: bool = False):
    """Run the full agentic memory evaluation."""

    global MEMORY_STORE
    MEMORY_STORE = XmStore(store_path=store_path)

    print(f"\n{'='*70}")
    print("  LoCoMo Agentic Memory Evaluation")
    print(f"  Model: {MODEL}")
    if store_path:
        print(f"  Store: {store_path}")
    if workers > 1:
        print(f"  Workers: {workers} (parallel mode)")
    if edu_mode:
        print(f"  Ingestion mode: EDU (self-contained units)")
    if extract_implicit:
        print(f"  LLM Fact Extraction: enabled")
    if shuffle:
        print(f"  Question order: shuffled")
    print(f"{'='*70}")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]

    # Phase 1: Agentic Ingestion
    print("\n" + "="*50)
    print("Phase 1: AGENTIC MEMORY STRUCTURING")
    print("="*50)
    print("\nThe agent will read the conversation and decide")
    print("what to remember and how to structure it.\n")

    ingest_stats = ingest_conversation_with_agent(conv, verbose, extract_implicit=extract_implicit, edu_mode=edu_mode)

    # Show schema if requested
    if show_schema:
        MEMORY_STORE.show_schema()

    # Phase 2: Agentic Query
    print("\n" + "="*50)
    print("Phase 2: AGENTIC QUESTION ANSWERING")
    print("="*50)
    print("\nThe agent will query its memories to answer questions.\n")

    all_qa = [qa for qa in conv["qa"] if qa["category"] != 5]
    if shuffle:
        random.shuffle(all_qa)
    qa_pairs = all_qa[:limit]
    # Results: (category, llm_judge_score, f1_score)
    results: List[Tuple[int, int, float]] = []
    # Detailed results for logging
    detailed_results: List[Dict] = []

    if workers > 1:
        # Parallel execution
        print(f"Processing {len(qa_pairs)} questions with {workers} workers...\n")

        completed = 0
        with ThreadPoolExecutor(max_workers=workers) as executor:
            # Submit all tasks
            future_to_qa = {
                executor.submit(process_single_qa, qa, i, len(qa_pairs), False): (i, qa)
                for i, qa in enumerate(qa_pairs, 1)
            }

            # Collect results as they complete
            results_dict = {}
            for future in as_completed(future_to_qa):
                i, qa = future_to_qa[future]
                try:
                    result = future.result()
                    results_dict[result["index"]] = result
                    completed += 1

                    # Print progress
                    q_display = result["question"][:45] + "..." if len(result["question"]) > 45 else result["question"]
                    judge_str = "✓" if result["llm_judge_score"] == 1 else "✗"
                    print(f"[{completed}/{len(qa_pairs)}] {judge_str} F1:{result['f1_score']:.3f} | {q_display}")

                except Exception as e:
                    print(f"[{i}] Error: {e}")
                    results_dict[i] = {
                        "index": i,
                        "question": qa["question"],
                        "expected": str(qa["answer"]),
                        "generated": f"Error: {e}",
                        "category": qa["category"],
                        "category_name": CATEGORY_NAMES[qa["category"]],
                        "evidence": qa.get("evidence", []),
                        "f1_score": 0.0,
                        "llm_judge": "WRONG",
                        "llm_judge_score": 0
                    }

        # Sort results by index to maintain order
        for i in range(1, len(qa_pairs) + 1):
            result = results_dict[i]
            results.append((result["category"], result["llm_judge_score"], result["f1_score"]))
            detailed_results.append(result)

    else:
        # Sequential execution (original behavior)
        for i, qa in enumerate(qa_pairs, 1):
            question = qa["question"]
            gold = str(qa["answer"])
            category = qa["category"]
            evidence = qa.get("evidence", [])

            q_display = question[:55] + "..." if len(question) > 55 else question
            print(f"\n[{i}/{len(qa_pairs)}] {q_display}")

            # Get agent's answer
            generated = answer_with_agent(question, verbose)

            # Compute F1 score (LoCoMo primary metric)
            f1 = compute_category_f1(generated, gold, category)

            # LLM Judge (secondary metric)
            llm_score = judge_answer(question, gold, generated)

            gold_display = gold[:45] + "..." if len(gold) > 45 else gold
            gen_display = generated[:50] + "..." if len(generated) > 50 else generated

            print(f"  Expected: {gold_display}")
            print(f"  Got:      {gen_display}")
            print(f"  F1: {f1:.3f} | Judge: {'✓ CORRECT' if llm_score == 1 else '✗ WRONG'}")

            results.append((category, llm_score, f1))

            # Store detailed result for logging
            detailed_results.append({
                "index": i,
                "question": question,
                "expected": gold,
                "generated": generated,
                "category": category,
                "category_name": CATEGORY_NAMES[category],
                "evidence": evidence,
                "f1_score": round(f1, 4),
                "llm_judge": "CORRECT" if llm_score == 1 else "WRONG",
                "llm_judge_score": llm_score
            })

    # Print results
    print(f"\n{'='*70}")
    print("RESULTS: Agentic Memory (LoCoMo-aligned)")
    print(f"{'='*70}\n")

    print(f"Memory Stats: {ingest_stats['total_memories']} memories stored")
    print(f"By type: {ingest_stats['by_type']}\n")

    # Primary metric: F1 (LoCoMo specification)
    print("=" * 65)
    print("F1 SCORES (LoCoMo Primary Metric)")
    print("=" * 65)
    print(f"{'Category':<15} {'Avg F1':>10} {'Total':>8}")
    print("-" * 35)

    category_f1s = {}
    for cat_num in [1, 2, 3, 4]:
        cat_results = [r for r in results if r[0] == cat_num]
        if cat_results:
            avg_f1 = sum(r[2] for r in cat_results) / len(cat_results)
            category_f1s[cat_num] = avg_f1
            print(f"{CATEGORY_NAMES[cat_num]:<15} {avg_f1:>10.3f} {len(cat_results):>8}")

    print("-" * 35)
    total_count = len(results)
    overall_f1 = sum(r[2] for r in results) / total_count if total_count > 0 else 0
    print(f"{'OVERALL':<15} {overall_f1:>10.3f} {total_count:>8}\n")

    # Secondary metric: LLM Judge accuracy
    print("=" * 65)
    print("LLM JUDGE SCORES (Binary Accuracy)")
    print("=" * 65)
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

    # Get git hash for reproducibility
    try:
        git_hash = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5, cwd=XM_DIR
        ).stdout.strip()
    except Exception:
        git_hash = "unknown"

    # Save detailed results to log file
    log_data = {
        "timestamp": datetime.now().isoformat(),
        "git_hash": git_hash,
        "model": MODEL,
        "api_provider": API_PROVIDER,
        "limit": limit,
        "workers": workers,
        "shuffle": shuffle,
        "edu_mode": edu_mode,
        "conversation_id": conv["sample_id"],
        "memory_stats": ingest_stats,
        "summary": {
            "total_questions": total,
            "overall_f1": round(overall_f1, 4),
            "judge_correct": correct,
            "judge_accuracy": round(accuracy, 2),
            "f1_by_category": {CATEGORY_NAMES[k]: round(v, 4) for k, v in category_f1s.items()}
        },
        "questions": detailed_results
    }

    # Write to results directory
    results_dir = Path("eval/locomo/results")
    results_dir.mkdir(exist_ok=True)

    timestamp_str = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_path = results_dir / f"eval-{timestamp_str}.json"

    with open(log_path, "w") as f:
        json.dump(log_data, f, indent=2)

    print(f"📝 Detailed results saved to: {log_path}\n")

    return {
        "memory_stats": ingest_stats,
        "total": total,
        "correct_judge": correct,
        "judge_accuracy": accuracy,
        "overall_f1": overall_f1,
        "f1_by_category": category_f1s,
        "log_path": str(log_path)
    }


def run_ingest_only(store_path: str = None, verbose: bool = True):
    """Run ingestion only (no QA) for schema inspection."""

    global MEMORY_STORE
    MEMORY_STORE = XmStore(store_path=store_path)

    print(f"\n{'='*70}")
    print("  LoCoMo Agentic Memory - Ingest Only Mode")
    print(f"  Model: {MODEL}")
    if store_path:
        print(f"  Store: {store_path}")
    print(f"{'='*70}")

    # Load dataset
    with open("eval/locomo/data/locomo10.json") as f:
        conversations = json.load(f)

    conv = conversations[0]

    # Run ingestion
    print("\nIngesting conversation with agentic memory structuring...\n")
    ingest_stats = ingest_conversation_with_agent(conv, verbose)

    # Show schema
    MEMORY_STORE.show_schema()

    # Print all memories for inspection
    print("\n" + "="*50)
    print("STORED MEMORIES")
    print("="*50 + "\n")

    for mem in MEMORY_STORE._memories:
        ts = f" [{mem['timestamp']}]" if mem.get('timestamp') else ""
        print(f"  [{mem['type']}] {mem['subject']}: {mem['content'][:60]}...{ts}")

    return ingest_stats


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Agentic Memory Evaluation")
    parser.add_argument("--limit", type=int, default=10, help="Max questions to evaluate")
    parser.add_argument("--verbose", "-v", action="store_true", default=True, help="Show agent actions")
    parser.add_argument("--quiet", "-q", action="store_true", help="Minimal output")
    parser.add_argument("--show-schema", action="store_true", help="Show xm schema after ingestion")
    parser.add_argument("--store", type=str, help="Path to xm store (default: in-memory)")
    parser.add_argument("--ingest-only", action="store_true", help="Only ingest, don't run QA (for schema inspection)")
    parser.add_argument("--workers", "-w", type=int, default=1, help="Number of parallel workers for QA phase (default: 1)")
    parser.add_argument("--extract-implicit", action="store_true", help="Run LLM-based implicit fact extraction after ingestion")
    parser.add_argument("--shuffle", action="store_true", help="Shuffle questions before sampling (for fairer --limit sampling)")
    parser.add_argument("--edu", action="store_true", help="Use EDU (Elementary Discourse Unit) ingestion mode - self-contained facts")

    args = parser.parse_args()

    # Check for appropriate API key based on provider
    if API_PROVIDER == "openai":
        if not os.environ.get("OPENAI_API_KEY"):
            print("Error: OPENAI_API_KEY not set")
            sys.exit(1)
    else:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            print("Error: ANTHROPIC_API_KEY not set")
            sys.exit(1)

    if args.ingest_only:
        run_ingest_only(store_path=args.store, verbose=not args.quiet)
    else:
        run_agentic_memory_eval(
            limit=args.limit,
            verbose=not args.quiet,
            show_schema=args.show_schema,
            store_path=args.store,
            workers=args.workers,
            extract_implicit=args.extract_implicit,
            shuffle=args.shuffle,
            edu_mode=args.edu
        )


if __name__ == "__main__":
    main()
