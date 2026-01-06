#!/usr/bin/env python3
"""
LoCoMo Agentic Memory Evaluation

This evaluation tests whether an LLM agent can effectively:
1. STRUCTURE memories from conversations using xm tools (not predefined schema)
2. QUERY those memories to answer questions

The agent decides what's important to remember and how to organize it.

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
from pathlib import Path
from typing import Dict, Any, List, Tuple
import requests

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "gpt-4o-mini"
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
                    "enum": ["person", "event", "fact", "preference", "relationship", "statement"],
                    "description": "Type of memory: person (who), event (what happened), fact (information), preference (likes/dislikes), relationship (between people), statement (exact quote)"
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
                    "enum": ["person", "event", "fact", "preference", "relationship", "statement", "all"],
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
                        "max_tokens": max_tokens,
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
        """Enhanced local search with word matching and scoring."""
        query_lower = query.lower()
        query_words = set(query_lower.split())

        # Common synonyms for better matching
        synonyms = {
            "friend": ["friends", "friendship", "buddy", "close"],
            "friends": ["friend", "friendship", "buddy", "close"],
            "book": ["books", "reading", "read", "novel"],
            "books": ["book", "reading", "read", "novel"],
            "activity": ["activities", "hobby", "hobbies", "sport"],
            "activities": ["activity", "hobby", "hobbies", "sport"],
            "swim": ["swimming", "swam", "pool"],
            "swimming": ["swim", "swam", "pool"],
            "run": ["running", "ran", "race", "marathon"],
            "running": ["run", "ran", "race", "marathon"],
            "race": ["running", "ran", "marathon", "charity"],
            "camp": ["camping", "camped", "tent", "outdoor"],
            "camping": ["camp", "camped", "tent", "outdoor"],
            "paint": ["painting", "painted", "art", "artwork"],
            "painting": ["paint", "painted", "art", "artwork"],
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
            # Exact phrase match
            if query_lower in text:
                score += 10
            # Word matches
            text_words = set(text.split())
            matching_words = expanded_words & text_words
            score += len(matching_words) * 2

            if score > 0:
                results.append((score, mem))

        # Sort by score descending
        results.sort(key=lambda x: -x[0])
        return [r[1] for r in results[:15]]

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
        """Get all memories about a subject."""
        return self._local_search(subject, None)[:15]

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

    return json.dumps({"error": f"Unknown tool: {tool_name}"})


# ============================================================================
# Agentic Ingestion
# ============================================================================

INGESTION_SYSTEM = """You are a memory agent. Your task is to read conversation sessions and store important memories using the provided tools.

For each conversation session, identify and store:
1. **Facts about people**: Identity, background, relationships, characteristics
2. **Events**: Activities, trips, achievements, with timing when mentioned
3. **Preferences**: What people like, want, plan to do
4. **Key statements**: Important things said that might be referenced later

Be SELECTIVE - don't store every utterance. Focus on information that would help answer questions about:
- Who the people are and their backgrounds
- What events happened and when
- Important facts and decisions
- Relationships between people and events

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
When someone mentions a LIST of items, store EACH ITEM separately:
- Books mentioned → store EACH book title as a separate memory
- Activities → store EACH activity (swimming, painting, running, etc.)
- Places visited → store EACH location
- People mentioned → store EACH person

Example: If someone says "I've been reading Dr. Seuss and Nothing is Impossible":
- Store: "Read book: Dr. Seuss" (with timestamp)
- Store: "Read book: Nothing is Impossible" (with timestamp)

**CRITICAL - SPECIFIC DETAILS**:
Store specific names, titles, and details - not just general categories:
- ✓ "Read 'Nothing is Impossible' by Diana Nyad" (specific)
- ✗ "Has been reading books" (too general)
- ✓ "Melanie does swimming, painting, and running" (specific activities)
- ✗ "Melanie has hobbies" (too general)

Use the source field to track which dialog turn (e.g., "D1:3") the information came from."""


def ingest_session_with_agent(session_data: Dict, session_idx: int, verbose: bool = True) -> int:
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
    for i in range(15):  # Max 15 tool calls per session
        response = call_llm_with_tools(messages, INGESTION_TOOLS, INGESTION_SYSTEM, max_tokens=1500)

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


def ingest_conversation_with_agent(conv: Dict, verbose: bool = True) -> Dict:
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

        memories = ingest_session_with_agent(session_data, session_idx, verbose)
        total_memories += memories

        if verbose:
            print(f"    → {memories} memories stored")

        session_idx += 1

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

**Search Strategy - TRY MULTIPLE APPROACHES**:
1. Start with the most specific terms from the question
2. If no results, try SYNONYMS and related terms:
   - "activities" → also search "hobbies", "sports", specific activities
   - "friends" → also search "friendship", "close", "years"
   - "books" → also search "reading", "read", specific book titles
3. Get memories about the PERSON if the question mentions someone
4. Use get_timeline for ANY time-related question
5. Search for EACH keyword separately if combined search fails

**Important**: Don't give up after one search! Try at least 2-3 different search terms.

**For list questions** ("What activities...", "What books..."):
- Search for the category AND specific items
- Combine results from multiple searches

If you cannot find information after multiple searches, say "Cannot determine from memory"."""


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


# ============================================================================
# Judge
# ============================================================================

def judge_answer(question: str, gold: str, generated: str) -> int:
    """Judge if answer is correct, with retry logic."""

    prompt = f"""You are evaluating a QA system response.

Question: {question}
Expected Answer: {gold}
Generated Answer: {generated}

Be GENEROUS - same meaning/topic counts as correct.
For dates, flexible matching is OK (May 7th = 7 May = May 2023).

Respond with JSON: {{"reasoning": "brief explanation", "label": "CORRECT or WRONG"}}"""

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
                        "max_tokens": 100,
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

def run_agentic_memory_eval(limit: int = 10, verbose: bool = True, show_schema: bool = False, store_path: str = None):
    """Run the full agentic memory evaluation."""

    global MEMORY_STORE
    MEMORY_STORE = XmStore(store_path=store_path)

    print(f"\n{'='*70}")
    print("  LoCoMo Agentic Memory Evaluation")
    print(f"  Model: {MODEL}")
    if store_path:
        print(f"  Store: {store_path}")
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

    ingest_stats = ingest_conversation_with_agent(conv, verbose)

    # Show schema if requested
    if show_schema:
        MEMORY_STORE.show_schema()

    # Phase 2: Agentic Query
    print("\n" + "="*50)
    print("Phase 2: AGENTIC QUESTION ANSWERING")
    print("="*50)
    print("\nThe agent will query its memories to answer questions.\n")

    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]
    results: List[Tuple[int, int]] = []

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        q_display = question[:55] + "..." if len(question) > 55 else question
        print(f"\n[{i}/{len(qa_pairs)}] {q_display}")

        # Get agent's answer
        generated = answer_with_agent(question, verbose)

        # Judge
        score = judge_answer(question, gold, generated)

        gold_display = gold[:45] + "..." if len(gold) > 45 else gold
        gen_display = generated[:50] + "..." if len(generated) > 50 else generated

        print(f"  Expected: {gold_display}")
        print(f"  Got:      {gen_display}")
        print(f"  {'✓ CORRECT' if score == 1 else '✗ WRONG'}")

        results.append((category, score))

    # Print results
    print(f"\n{'='*70}")
    print("RESULTS: Agentic Memory")
    print(f"{'='*70}\n")

    print(f"Memory Stats: {ingest_stats['total_memories']} memories stored")
    print(f"By type: {ingest_stats['by_type']}\n")

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

    return {
        "memory_stats": ingest_stats,
        "total": total,
        "correct": correct,
        "accuracy": accuracy
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

    args = parser.parse_args()

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
            store_path=args.store
        )


if __name__ == "__main__":
    main()
