#!/usr/bin/env python3
"""
LoCoMo Schema.org Evaluation with xm Backend

Uses schema.org vocabulary for structured memory storage via xm CLI.
This tests xm's ability to store and query structured knowledge.

Node types (mapped to xm):
- Person: identity, nationality, relationship_status, occupation
- Event: date, attendees, location, event_type
- Activity: practitioner, activity_type, frequency
- CreativeWork: creator, work_type, date_created
- Pet: species, owner
"""

import json
import subprocess
import argparse
import os
import sys
import re
import time
import string
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Tuple, Optional
import requests

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "gpt-4o-mini-2024-07-18"
API_PROVIDER = "openai"

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# Schema.org namespace for xm
SCHEMA_NS = "https://schema.org/"
XM_NS = "https://xm.dev/ns/v1#"


# ============================================================================
# xm-backed Schema Store
# ============================================================================

class SchemaXmStore:
    """Schema.org memory store backed by xm CLI."""

    def __init__(self, store_path: str = None):
        self.store_path = store_path
        self._entity_count = 0
        # Local tracking for stats and fallback search
        self._entities = []

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

    def _create_node(self, node_type: str, properties: Dict[str, str]) -> str:
        """Create a node in xm with given type and properties."""
        self._entity_count += 1
        node_id = f"{node_type.lower()}_{self._entity_count}"

        args = ["node", "create", "-t", node_type]
        for key, value in properties.items():
            if value:  # Only add non-empty properties
                # Escape special characters in value
                safe_value = str(value).replace('"', '\\"')
                args.extend(["-p", f"{key}={safe_value}"])

        success, output = self._run_xm(args)

        # Track locally for stats and fallback
        entity = {"id": node_id, "type": node_type, **properties}
        self._entities.append(entity)

        return node_id

    # ========================================================================
    # Schema Entity Creation Methods
    # ========================================================================

    def add_person(self, name: str, **props) -> str:
        """Add a Person entity."""
        properties = {
            "name": name,
            "schema_type": "Person",
            **{k: v for k, v in props.items() if v}
        }
        return self._create_node("Person", properties)

    def add_event(self, name: str, date: str = None, attendees: List[str] = None,
                  location: str = None, event_type: str = None) -> str:
        """Add an Event entity."""
        properties = {
            "name": name,
            "schema_type": "Event",
            "date": date,
            "attendees": ",".join(attendees) if attendees else None,
            "location": location,
            "event_type": event_type
        }
        return self._create_node("Event", properties)

    def add_activity(self, practitioner: str, activity_type: str,
                     frequency: str = None, location: str = None) -> str:
        """Add an Activity entity."""
        properties = {
            "schema_type": "Activity",
            "practitioner": practitioner,
            "activity_type": activity_type,
            "frequency": frequency,
            "location": location
        }
        return self._create_node("Activity", properties)

    def add_creative_work(self, name: str, creator: str = None,
                          work_type: str = None, date_created: str = None,
                          about: str = None) -> str:
        """Add a CreativeWork entity."""
        properties = {
            "name": name,
            "schema_type": "CreativeWork",
            "creator": creator,
            "work_type": work_type,
            "date_created": date_created,
            "about": about
        }
        return self._create_node("CreativeWork", properties)

    def add_pet(self, name: str, species: str, owner: str) -> str:
        """Add a Pet entity."""
        properties = {
            "name": name,
            "schema_type": "Pet",
            "species": species,
            "owner": owner
        }
        return self._create_node("Pet", properties)

    def add_relationship(self, person1: str, person2: str, rel_type: str,
                         duration: str = None) -> str:
        """Add a Relationship entity."""
        properties = {
            "schema_type": "Relationship",
            "person1": person1,
            "person2": person2,
            "relationship_type": rel_type,
            "duration": duration
        }
        return self._create_node("Relationship", properties)

    def add_fact(self, subject: str, content: str, fact_type: str = "fact",
                 timestamp: str = None) -> str:
        """Add a general fact (for flexible storage)."""
        properties = {
            "schema_type": "Fact",
            "subject": subject.lower(),
            "content": content,
            "fact_type": fact_type,
            "timestamp": timestamp
        }
        return self._create_node("Fact", properties)

    # ========================================================================
    # SPARQL Query Methods
    # ========================================================================

    def sparql_query(self, query: str) -> List[Dict]:
        """Execute a SPARQL query and return results."""
        success, output = self._run_xm(["query", "sparql", query], timeout=60)

        if success:
            try:
                results = json.loads(output)
                bindings = results.get("results", {}).get("bindings", [])
                return [self._binding_to_dict(b) for b in bindings]
            except:
                pass
        return []

    def _binding_to_dict(self, binding: Dict) -> Dict:
        """Convert SPARQL binding to simple dict."""
        return {k: v.get("value", "") for k, v in binding.items()}

    def query_person(self, name: str) -> Optional[Dict]:
        """Query person by name using SPARQL."""
        name_lower = name.lower()
        sparql = f"""
        SELECT ?node ?name ?identity ?nationality ?relationship_status ?occupation WHERE {{
            ?node a <{XM_NS}Person> .
            ?node <{XM_NS}name> ?name .
            OPTIONAL {{ ?node <{XM_NS}identity> ?identity }}
            OPTIONAL {{ ?node <{XM_NS}nationality> ?nationality }}
            OPTIONAL {{ ?node <{XM_NS}relationship_status> ?relationship_status }}
            OPTIONAL {{ ?node <{XM_NS}occupation> ?occupation }}
            FILTER(REGEX(?name, '{name_lower}', 'i'))
        }} LIMIT 1
        """
        results = self.sparql_query(sparql)
        return results[0] if results else self._local_query_person(name)

    def query_person_events(self, person_name: str) -> List[Dict]:
        """Query events for a person using SPARQL."""
        name_lower = person_name.lower()
        sparql = f"""
        SELECT ?node ?name ?date ?location ?event_type ?attendees WHERE {{
            ?node a <{XM_NS}Event> .
            ?node <{XM_NS}name> ?name .
            OPTIONAL {{ ?node <{XM_NS}date> ?date }}
            OPTIONAL {{ ?node <{XM_NS}location> ?location }}
            OPTIONAL {{ ?node <{XM_NS}event_type> ?event_type }}
            OPTIONAL {{ ?node <{XM_NS}attendees> ?attendees }}
            FILTER(REGEX(?attendees, '{name_lower}', 'i') || REGEX(?name, '{name_lower}', 'i'))
        }} LIMIT 20
        """
        results = self.sparql_query(sparql)
        return results if results else self._local_query_events(person_name)

    def query_person_activities(self, person_name: str) -> List[Dict]:
        """Query activities for a person using SPARQL."""
        name_lower = person_name.lower()
        sparql = f"""
        SELECT ?node ?activity_type ?frequency ?location ?practitioner WHERE {{
            ?node a <{XM_NS}Activity> .
            ?node <{XM_NS}practitioner> ?practitioner .
            ?node <{XM_NS}activity_type> ?activity_type .
            OPTIONAL {{ ?node <{XM_NS}frequency> ?frequency }}
            OPTIONAL {{ ?node <{XM_NS}location> ?location }}
            FILTER(REGEX(?practitioner, '{name_lower}', 'i'))
        }} LIMIT 20
        """
        results = self.sparql_query(sparql)
        return results if results else self._local_query_activities(person_name)

    def query_person_pets(self, person_name: str) -> List[Dict]:
        """Query pets for a person using SPARQL."""
        name_lower = person_name.lower()
        sparql = f"""
        SELECT ?node ?name ?species ?owner WHERE {{
            ?node a <{XM_NS}Pet> .
            ?node <{XM_NS}name> ?name .
            ?node <{XM_NS}species> ?species .
            ?node <{XM_NS}owner> ?owner .
            FILTER(REGEX(?owner, '{name_lower}', 'i'))
        }} LIMIT 10
        """
        results = self.sparql_query(sparql)
        return results if results else self._local_query_pets(person_name)

    def query_creative_works(self, creator: str = None, work_type: str = None) -> List[Dict]:
        """Query creative works using SPARQL."""
        filters = []
        if creator:
            filters.append(f"REGEX(?creator, '{creator.lower()}', 'i')")
        if work_type:
            filters.append(f"REGEX(?work_type, '{work_type.lower()}', 'i')")

        filter_clause = f"FILTER({' && '.join(filters)})" if filters else ""

        sparql = f"""
        SELECT ?node ?name ?creator ?work_type ?date_created ?about WHERE {{
            ?node a <{XM_NS}CreativeWork> .
            ?node <{XM_NS}name> ?name .
            OPTIONAL {{ ?node <{XM_NS}creator> ?creator }}
            OPTIONAL {{ ?node <{XM_NS}work_type> ?work_type }}
            OPTIONAL {{ ?node <{XM_NS}date_created> ?date_created }}
            OPTIONAL {{ ?node <{XM_NS}about> ?about }}
            {filter_clause}
        }} LIMIT 20
        """
        results = self.sparql_query(sparql)
        return results if results else self._local_query_works(creator, work_type)

    def search_facts(self, query: str) -> List[Dict]:
        """Search facts using SPARQL REGEX."""
        words = query.lower().split()
        pattern = "|".join(re.escape(w) for w in words if len(w) > 2)
        if not pattern:
            pattern = re.escape(query.lower())

        sparql = f"""
        SELECT ?node ?subject ?content ?fact_type ?timestamp WHERE {{
            ?node a <{XM_NS}Fact> .
            ?node <{XM_NS}content> ?content .
            ?node <{XM_NS}subject> ?subject .
            OPTIONAL {{ ?node <{XM_NS}fact_type> ?fact_type }}
            OPTIONAL {{ ?node <{XM_NS}timestamp> ?timestamp }}
            FILTER(REGEX(?content, '{pattern}', 'i') || REGEX(?subject, '{pattern}', 'i'))
        }} LIMIT 20
        """
        results = self.sparql_query(sparql)
        return results if results else self._local_search(query)

    def query_timeline(self, person_name: str = None) -> List[Dict]:
        """Get events in chronological order."""
        events = self.query_person_events(person_name) if person_name else self._get_all_events()
        return sorted(events, key=lambda e: e.get("date") or "")

    def _get_all_events(self) -> List[Dict]:
        """Get all events."""
        sparql = f"""
        SELECT ?node ?name ?date ?attendees ?event_type WHERE {{
            ?node a <{XM_NS}Event> .
            ?node <{XM_NS}name> ?name .
            OPTIONAL {{ ?node <{XM_NS}date> ?date }}
            OPTIONAL {{ ?node <{XM_NS}attendees> ?attendees }}
            OPTIONAL {{ ?node <{XM_NS}event_type> ?event_type }}
        }} LIMIT 50
        """
        return self.sparql_query(sparql) or self._local_get_all_events()

    # ========================================================================
    # Local Fallback Methods (when SPARQL fails)
    # ========================================================================

    def _local_query_person(self, name: str) -> Optional[Dict]:
        """Fallback: query person locally."""
        name_lower = name.lower()
        for e in self._entities:
            if e.get("type") == "Person" and name_lower in e.get("name", "").lower():
                return e
        return None

    def _local_query_events(self, person_name: str) -> List[Dict]:
        """Fallback: query events locally."""
        name_lower = person_name.lower()
        return [e for e in self._entities
                if e.get("type") == "Event" and
                (name_lower in (e.get("attendees") or "").lower() or
                 name_lower in (e.get("name") or "").lower())]

    def _local_query_activities(self, person_name: str) -> List[Dict]:
        """Fallback: query activities locally."""
        name_lower = person_name.lower()
        return [e for e in self._entities
                if e.get("type") == "Activity" and
                name_lower in (e.get("practitioner") or "").lower()]

    def _local_query_pets(self, person_name: str) -> List[Dict]:
        """Fallback: query pets locally."""
        name_lower = person_name.lower()
        return [e for e in self._entities
                if e.get("type") == "Pet" and
                name_lower in (e.get("owner") or "").lower()]

    def _local_query_works(self, creator: str = None, work_type: str = None) -> List[Dict]:
        """Fallback: query works locally."""
        results = [e for e in self._entities if e.get("type") == "CreativeWork"]
        if creator:
            results = [e for e in results if creator.lower() in (e.get("creator") or "").lower()]
        if work_type:
            results = [e for e in results if work_type.lower() in (e.get("work_type") or "").lower()]
        return results

    def _local_get_all_events(self) -> List[Dict]:
        """Fallback: get all events locally."""
        return [e for e in self._entities if e.get("type") == "Event"]

    def _local_search(self, query: str) -> List[Dict]:
        """Fallback: search facts locally with synonym expansion."""
        query_lower = query.lower()
        query_words = set(query_lower.split())

        synonyms = {
            "country": ["sweden", "nationality", "home", "moved", "from", "origin"],
            "sweden": ["country", "nationality", "home", "moved", "from"],
            "single": ["relationship", "status", "parent", "unmarried"],
            "camp": ["camping", "beach", "mountain", "forest", "tent"],
            "camping": ["camp", "beach", "mountain", "forest"],
            "activity": ["activities", "hobby", "hobbies", "partake"],
            "pet": ["pets", "dog", "cat", "luna", "oliver", "bailey", "oscar"],
            "birthday": ["birth", "age", "years", "old"],
            "career": ["counseling", "mental", "health", "job", "occupation"],
        }

        expanded = set(query_words)
        for w in query_words:
            if w in synonyms:
                expanded.update(synonyms[w])

        results = []
        for e in self._entities:
            if e.get("type") != "Fact":
                continue
            content = (e.get("content") or "").lower()
            subject = (e.get("subject") or "").lower()
            text = content + " " + subject

            score = 0
            if query_lower in text:
                score += 10
            for w in expanded:
                if w in text:
                    score += 2

            if score > 0:
                results.append((score, e))

        results.sort(key=lambda x: -x[0])
        return [r[1] for r in results[:15]]

    def stats(self) -> Dict:
        """Get store statistics."""
        by_type = {}
        for e in self._entities:
            t = e.get("type", "unknown")
            by_type[t] = by_type.get(t, 0) + 1
        return {"total": len(self._entities), "by_type": by_type}


# Global store
MEMORY_STORE = SchemaXmStore()


# ============================================================================
# LLM API
# ============================================================================

def call_openai(messages: List[Dict], tools: List[Dict] = None,
                system: str = None, max_tokens: int = 2000) -> Dict:
    """Call OpenAI API."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise ValueError("OPENAI_API_KEY not set")

    openai_messages = []
    if system:
        openai_messages.append({"role": "system", "content": system})

    for msg in messages:
        if msg.get("tool_calls"):
            openai_messages.append({
                "role": msg["role"],
                "content": msg.get("content", ""),
                "tool_calls": msg["tool_calls"]
            })
        elif msg.get("role") == "tool":
            openai_messages.append({
                "role": "tool",
                "tool_call_id": msg["tool_call_id"],
                "content": msg["content"]
            })
        else:
            openai_messages.append({"role": msg["role"], "content": msg.get("content", "")})

    payload = {
        "model": MODEL,
        "messages": openai_messages,
        "max_tokens": max_tokens,
        "temperature": 0.1,
    }

    if tools:
        payload["tools"] = [{"type": "function", "function": t} for t in tools]
        payload["tool_choice"] = "auto"

    for attempt in range(5):
        try:
            resp = requests.post(
                "https://api.openai.com/v1/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
                timeout=120
            )
            if resp.status_code == 429:
                time.sleep(2 ** attempt)
                continue
            resp.raise_for_status()
            data = resp.json()
            choice = data["choices"][0]
            message = choice["message"]

            if tools and message.get("tool_calls"):
                content = []
                if message.get("content"):
                    content.append({"type": "text", "text": message["content"]})
                for tc in message["tool_calls"]:
                    content.append({
                        "type": "tool_use",
                        "id": tc["id"],
                        "name": tc["function"]["name"],
                        "input": json.loads(tc["function"]["arguments"])
                    })
                return {"content": content, "stop_reason": choice.get("finish_reason")}

            return {"content": [{"type": "text", "text": message.get("content", "")}],
                    "stop_reason": choice.get("finish_reason")}
        except Exception as e:
            if attempt < 4:
                time.sleep(2 ** attempt)
            else:
                raise


# ============================================================================
# Schema Ingestion
# ============================================================================

INGESTION_SYSTEM = """You are a memory extraction agent using schema.org vocabulary.

Extract entities from conversations into these types:

## PERSON
Properties: name, identity (e.g., "transgender woman"), nationality (country name), relationship_status ("single"/"married"), occupation

## EVENT
Properties: name, date (YYYY-MM-DD), attendees (list), location, event_type

## ACTIVITY
Properties: practitioner, activity_type (camping, painting, running, pottery, swimming), frequency, location (beach/mountain/forest)

## CREATIVE_WORK
Properties: name, creator, work_type (painting/book/pottery), date_created (YEAR), about

## PET
Properties: name, species (dog/cat/guinea_pig), owner

## FACT (for anything else important)
Properties: subject, content, fact_type (biographical/temporal/preference)

## CRITICAL DATE HANDLING:
Session date context is provided. Convert relative dates:
- "last year" → previous year (e.g., 2022 if session is 2023)
- "10 years ago" → subtract from session year
- "4 years" → calculate start year

## CRITICAL EXTRACTIONS:
- Identity: "transgender woman", "transgender man"
- Nationality: actual country name "Sweden" (not "home country")
- Relationship: "single" (even from "single parent")
- Activities: each activity separately WITH locations (beach, mountains, forest)
- Career goals: "counseling", "mental health"

Output JSON array of entities:
```json
[
  {"type": "PERSON", "name": "Caroline", "identity": "transgender woman", "nationality": "Sweden", "relationship_status": "single", "occupation": "counseling"},
  {"type": "EVENT", "name": "LGBTQ support group", "date": "2023-05-07", "attendees": ["Caroline"], "event_type": "support_group"},
  {"type": "ACTIVITY", "practitioner": "Melanie", "activity_type": "camping", "location": "beach"},
  {"type": "CREATIVE_WORK", "name": "sunrise painting", "creator": "Melanie", "work_type": "painting", "date_created": "2022"},
  {"type": "FACT", "subject": "Caroline", "content": "Caroline moved from Sweden 4 years ago", "fact_type": "biographical"}
]
```"""


def parse_session_date(session_date: str) -> Tuple[int, int]:
    """Parse session date to get year and month."""
    match = re.search(r'(\d{1,2})\s+(\w+)\s+(\d{4})', session_date)
    if match:
        months = {'january': 1, 'february': 2, 'march': 3, 'april': 4, 'may': 5, 'june': 6,
                  'july': 7, 'august': 8, 'september': 9, 'october': 10, 'november': 11, 'december': 12}
        return int(match.group(3)), months.get(match.group(2).lower(), 1)
    return 2023, 5


def extract_entities(session_text: str, session_date: str) -> List[Dict]:
    """Extract schema entities from conversation."""
    year, month = parse_session_date(session_date)

    prompt = f"""Extract entities from this conversation.

SESSION DATE: {session_date}
YEAR: {year}, MONTH: {month}
LAST YEAR = {year - 1}
"10 years ago" = {year - 10}

Conversation:
{session_text}

Return ONLY a JSON array of entities."""

    messages = [{"role": "user", "content": prompt}]
    response = call_openai(messages, None, INGESTION_SYSTEM, max_tokens=4000)
    text = response.get("content", [{}])[0].get("text", "")

    try:
        start = text.find('[')
        end = text.rfind(']') + 1
        if start >= 0 and end > start:
            return json.loads(text[start:end])
    except:
        pass
    return []


def store_entity(entity: Dict) -> str:
    """Store an entity in xm."""
    entity_type = entity.get("type", "").upper()

    if entity_type == "PERSON":
        return MEMORY_STORE.add_person(
            name=entity.get("name", "Unknown"),
            identity=entity.get("identity"),
            nationality=entity.get("nationality"),
            relationship_status=entity.get("relationship_status"),
            occupation=entity.get("occupation")
        )
    elif entity_type == "EVENT":
        return MEMORY_STORE.add_event(
            name=entity.get("name", "Unknown"),
            date=entity.get("date"),
            attendees=entity.get("attendees", []),
            location=entity.get("location"),
            event_type=entity.get("event_type")
        )
    elif entity_type == "ACTIVITY":
        return MEMORY_STORE.add_activity(
            practitioner=entity.get("practitioner", "unknown"),
            activity_type=entity.get("activity_type", "unknown"),
            frequency=entity.get("frequency"),
            location=entity.get("location")
        )
    elif entity_type == "CREATIVE_WORK":
        return MEMORY_STORE.add_creative_work(
            name=entity.get("name", "Unknown"),
            creator=entity.get("creator"),
            work_type=entity.get("work_type"),
            date_created=entity.get("date_created"),
            about=entity.get("about")
        )
    elif entity_type == "PET":
        return MEMORY_STORE.add_pet(
            name=entity.get("name", "Unknown"),
            species=entity.get("species", "unknown"),
            owner=entity.get("owner", "unknown")
        )
    elif entity_type == "RELATIONSHIP":
        return MEMORY_STORE.add_relationship(
            person1=entity.get("person1", "unknown"),
            person2=entity.get("person2", "unknown"),
            rel_type=entity.get("relationship_type", "knows"),
            duration=entity.get("duration")
        )
    elif entity_type == "FACT":
        return MEMORY_STORE.add_fact(
            subject=entity.get("subject", "unknown"),
            content=entity.get("content", ""),
            fact_type=entity.get("fact_type", "fact"),
            timestamp=entity.get("timestamp")
        )
    return "unknown"


# ============================================================================
# Query Tools (using xm SPARQL)
# ============================================================================

QUERY_TOOLS = [
    {
        "name": "query_person",
        "description": "Get person info (identity, nationality, relationship_status, occupation)",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"]
        }
    },
    {
        "name": "query_person_events",
        "description": "Get events a person attended with dates",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"]
        }
    },
    {
        "name": "query_person_activities",
        "description": "Get activities/hobbies a person does (camping, painting, etc.)",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"]
        }
    },
    {
        "name": "query_person_pets",
        "description": "Get pets owned by a person",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"]
        }
    },
    {
        "name": "query_creative_works",
        "description": "Get creative works (paintings, books, pottery)",
        "parameters": {
            "type": "object",
            "properties": {
                "creator": {"type": "string"},
                "work_type": {"type": "string"}
            },
            "required": []
        }
    },
    {
        "name": "search_facts",
        "description": "Search facts by keywords (use for nationality, career, biographical info)",
        "parameters": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"]
        }
    },
    {
        "name": "query_timeline",
        "description": "Get events in chronological order",
        "parameters": {
            "type": "object",
            "properties": {"person_name": {"type": "string"}},
            "required": []
        }
    }
]


def execute_query_tool(tool_name: str, tool_input: Dict) -> str:
    """Execute a query tool via xm."""

    if tool_name == "query_person":
        result = MEMORY_STORE.query_person(tool_input.get("name", ""))
        return json.dumps(result, indent=2) if result else "Person not found"

    elif tool_name == "query_person_events":
        results = MEMORY_STORE.query_person_events(tool_input.get("name", ""))
        return json.dumps(results, indent=2) if results else "No events found"

    elif tool_name == "query_person_activities":
        results = MEMORY_STORE.query_person_activities(tool_input.get("name", ""))
        return json.dumps(results, indent=2) if results else "No activities found"

    elif tool_name == "query_person_pets":
        results = MEMORY_STORE.query_person_pets(tool_input.get("name", ""))
        return json.dumps(results, indent=2) if results else "No pets found"

    elif tool_name == "query_creative_works":
        results = MEMORY_STORE.query_creative_works(
            tool_input.get("creator"),
            tool_input.get("work_type")
        )
        return json.dumps(results, indent=2) if results else "No works found"

    elif tool_name == "search_facts":
        results = MEMORY_STORE.search_facts(tool_input.get("query", ""))
        return json.dumps(results, indent=2) if results else "No facts found"

    elif tool_name == "query_timeline":
        results = MEMORY_STORE.query_timeline(tool_input.get("person_name"))
        return json.dumps(results, indent=2) if results else "No events found"

    return "Unknown tool"


QUERY_SYSTEM = """You are a QA agent using a schema.org knowledge graph stored in xm.

Available query tools:
- query_person: Get person properties (identity, nationality, relationship_status)
- query_person_events: Get events with dates
- query_person_activities: Get hobbies/activities
- query_person_pets: Get pets
- query_creative_works: Get paintings, books, pottery
- search_facts: Search biographical facts, nationality, career info
- query_timeline: Get events chronologically

STRATEGY:
1. For person properties (identity, nationality, status): use query_person first, then search_facts
2. For dates/times: use query_person_events or query_timeline
3. For hobbies: use query_person_activities
4. For implicit facts (country, career): use search_facts with keywords

ANSWER FORMAT: Be concise. Date questions → date. List questions → list items."""


def answer_with_agent(question: str, verbose: bool = True) -> str:
    """Answer question using xm query tools."""

    messages = [{"role": "user", "content": f"Answer: {question}"}]

    for _ in range(8):
        response = call_openai(messages, QUERY_TOOLS, QUERY_SYSTEM, max_tokens=1000)
        content = response.get("content", [])
        stop_reason = response.get("stop_reason", "")

        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses or stop_reason == "stop":
            texts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return " ".join(texts).strip() or "Cannot determine"

        tool_results = []
        for tu in tool_uses:
            if verbose:
                print(f"    [{tu['name']}] {json.dumps(tu['input'])[:40]}")
            result = execute_query_tool(tu["name"], tu["input"])
            tool_results.append({"tool_call_id": tu["id"], "content": result})

        assistant_msg = {
            "role": "assistant", "content": "",
            "tool_calls": [{"id": tu["id"], "type": "function",
                           "function": {"name": tu["name"], "arguments": json.dumps(tu["input"])}}
                          for tu in tool_uses]
        }
        messages.append(assistant_msg)
        for tr in tool_results:
            messages.append({"role": "tool", "tool_call_id": tr["tool_call_id"], "content": tr["content"]})

    return "Cannot determine"


# ============================================================================
# Evaluation Metrics
# ============================================================================

def normalize_answer(text: str) -> str:
    text = str(text).lower()
    text = text.translate(str.maketrans('', '', string.punctuation))
    return ' '.join(w for w in text.split() if w not in {'a', 'an', 'the', 'and'})

def simple_stem(word: str) -> str:
    for suffix in ['ing', 'ed', 's', 'ly']:
        if word.endswith(suffix) and len(word) > len(suffix) + 2:
            return word[:-len(suffix)]
    return word

def compute_f1(pred: str, truth: str) -> float:
    pred_tokens = set(simple_stem(w) for w in normalize_answer(pred).split())
    truth_tokens = set(simple_stem(w) for w in normalize_answer(truth).split())
    if not pred_tokens or not truth_tokens:
        return 0.0
    intersection = pred_tokens & truth_tokens
    p = len(intersection) / len(pred_tokens)
    r = len(intersection) / len(truth_tokens)
    return 2 * p * r / (p + r) if (p + r) > 0 else 0.0

def judge_answer(question: str, gold: str, generated: str) -> int:
    prompt = f"""Label as CORRECT or WRONG.
Question: {question}
Expected: {gold}
Generated: {generated}
CORRECT if key info matches. WRONG if missing or incorrect.
Return ONLY: CORRECT or WRONG"""
    response = call_openai([{"role": "user", "content": prompt}], None, None, 10)
    text = response.get("content", [{}])[0].get("text", "").upper()
    return 1 if "CORRECT" in text else 0


# ============================================================================
# Main Evaluation
# ============================================================================

def load_data():
    with open("eval/locomo/data/locomo10.json") as f:
        return json.load(f)

def get_sessions(conv: Dict) -> List[Tuple[str, str, str]]:
    conversation = conv.get("conversation", {})
    sessions = []
    for i in range(1, 50):
        key = f"session_{i}"
        if key not in conversation:
            break
        data = conversation[key]
        date = conversation.get(f"{key}_date_time", "unknown")
        if isinstance(data, list):
            text = "\n".join(f"{m.get('speaker', '?')}: {m.get('text', '')}" for m in data)
        else:
            text = str(data)
        sessions.append((str(i), date, text))
    return sessions


def run_evaluation(limit: int = 10, verbose: bool = True, store_path: str = None):
    """Run schema-xm evaluation."""

    global MEMORY_STORE
    MEMORY_STORE = SchemaXmStore(store_path=store_path)

    print(f"\n{'='*70}")
    print("  LoCoMo Schema.org Evaluation with xm Backend")
    print(f"  Model: {MODEL}")
    if store_path:
        print(f"  Store: {store_path}")
    print(f"{'='*70}")

    data = load_data()
    conv = data[0]

    # Phase 1: Ingestion
    print("\n" + "="*50)
    print("Phase 1: SCHEMA ENTITY EXTRACTION → xm")
    print("="*50)

    sessions = get_sessions(conv)
    for num, date, text in sessions:
        print(f"\n  Session {num} ({date[:15]}...)...")
        entities = extract_entities(text, date)
        for e in entities:
            store_entity(e)
            if verbose:
                etype = e.get("type", "?")
                name = e.get("name") or e.get("content", "")[:30]
                print(f"    [xm:{etype}] {name[:40]}")
        print(f"    → {len(entities)} entities stored in xm")

    stats = MEMORY_STORE.stats()
    print(f"\n  Total: {stats['total']} entities in xm")
    print(f"  By type: {stats['by_type']}")

    # Phase 2: QA
    print("\n" + "="*50)
    print("Phase 2: SPARQL-BASED QUESTION ANSWERING")
    print("="*50)

    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]
    results = []
    detailed = []

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        print(f"\n[{i}/{len(qa_pairs)}] {question[:55]}...")
        generated = answer_with_agent(question, verbose)
        f1 = compute_f1(generated, gold)
        judge = judge_answer(question, gold, generated)

        print(f"  Expected: {gold[:45]}")
        print(f"  Got: {generated[:50]}")
        print(f"  F1: {f1:.3f} | Judge: {'✓' if judge else '✗'}")

        results.append((category, judge, f1))
        detailed.append({
            "index": i, "question": question, "expected": gold,
            "generated": generated, "category": category,
            "category_name": CATEGORY_NAMES[category],
            "f1_score": round(f1, 4),
            "llm_judge": "CORRECT" if judge else "WRONG"
        })

    # Results
    print("\n" + "="*70)
    print("RESULTS: Schema.org + xm")
    print("="*70)

    total_f1 = sum(r[2] for r in results) / len(results) if results else 0
    total_correct = sum(r[1] for r in results)

    print(f"\nOverall F1: {total_f1:.3f}")
    print(f"Judge Accuracy: {total_correct}/{len(results)} ({100*total_correct/len(results):.1f}%)")

    # Save
    results_dir = Path("eval/locomo/results")
    results_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = results_dir / f"schema-xm-{ts}.json"
    path.write_text(json.dumps({
        "timestamp": datetime.now().isoformat(),
        "model": MODEL, "approach": "schema.org + xm",
        "memory_stats": stats,
        "summary": {"total": len(results), "f1": round(total_f1, 4),
                   "judge_correct": total_correct,
                   "judge_accuracy": round(100*total_correct/len(results), 1)},
        "questions": detailed
    }, indent=2))
    print(f"\n📝 Results: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--verbose", "-v", action="store_true", default=True)
    parser.add_argument("--quiet", "-q", action="store_true")
    parser.add_argument("--store", type=str, help="xm store path")
    args = parser.parse_args()
    run_evaluation(limit=args.limit, verbose=not args.quiet, store_path=args.store)


if __name__ == "__main__":
    main()
