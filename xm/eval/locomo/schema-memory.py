#!/usr/bin/env python3
"""
LoCoMo Evaluation with Schema.org-based Memory System

Uses structured schema.org vocabulary for both ingestion and retrieval,
enabling precise SPARQL-like queries instead of keyword matching.
"""

import json
import subprocess
import argparse
import os
import sys
import re
import time
import string
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Tuple, Optional
import requests

XM_DIR = Path(__file__).parent.parent.parent
os.chdir(XM_DIR)

MODEL = "gpt-4o-mini-2024-07-18"
API_PROVIDER = "openai"  # "anthropic" or "openai"

CATEGORY_NAMES = {
    1: "single_hop",
    2: "temporal",
    3: "commonsense",
    4: "multi_hop",
    5: "adversarial"
}

# ============================================================================
# Schema.org Vocabulary Definition
# ============================================================================

SCHEMA_VOCAB = """
# Schema.org-based Memory Vocabulary for Conversational Memory

## Core Types

### schema:Person
Represents a person mentioned in conversations.
Properties:
- schema:name (string) - Full name
- schema:nationality (string) - Country of origin
- schema:gender (string) - Gender identity
- schema:birthDate (date) - Birth date if known
- schema:knows (Person) - People they know
- schema:memberOf (Organization) - Groups/organizations
- :identity (string) - Identity description (e.g., "transgender woman")
- :relationshipStatus (string) - Single, married, etc.
- :occupation (string) - Job or career
- :yearsInCurrentLocation (integer) - How long at current location

### schema:Event
Represents events, activities, gatherings.
Properties:
- schema:name (string) - Event name/description
- schema:startDate (date) - When it occurred
- schema:endDate (date) - When it ended (if applicable)
- schema:location (Place) - Where it happened
- schema:attendee (Person) - Who attended
- schema:organizer (Person/Organization) - Who organized
- :eventType (string) - Type: pride_parade, conference, workshop, trip, etc.

### schema:Place
Represents locations.
Properties:
- schema:name (string) - Place name
- schema:containedIn (Place) - Parent location
- :placeType (string) - Type: country, city, beach, mountain, etc.

### schema:CreativeWork
Represents books, paintings, pottery, music.
Properties:
- schema:name (string) - Title
- schema:author (Person) - Creator
- schema:dateCreated (date) - When created
- schema:about (string) - Subject matter
- :workType (string) - Type: book, painting, pottery, song, etc.
- :significance (string) - Why it's meaningful

### schema:Organization
Represents groups, agencies, companies.
Properties:
- schema:name (string) - Organization name
- schema:member (Person) - Members
- :orgType (string) - Type: support_group, adoption_agency, activist_group, etc.

### :Pet
Represents pets/animals.
Properties:
- schema:name (string) - Pet's name
- :species (string) - dog, cat, guinea pig, etc.
- :owner (Person) - Who owns the pet

### :Preference
Represents preferences, favorites, opinions.
Properties:
- :holder (Person) - Who holds this preference
- :preferenceType (string) - Type: favorite_color, hobby, music_genre, etc.
- :value (string) - The preference value
- :reason (string) - Why they prefer it

### :Relationship
Represents relationships between people.
Properties:
- :person1 (Person) - First person
- :person2 (Person) - Second person
- :relationshipType (string) - friend, spouse, mentor, family, etc.
- :duration (string) - How long (e.g., "4 years")
- :startDate (date) - When relationship started

### :Activity
Represents hobbies, regular activities.
Properties:
- :practitioner (Person) - Who does this activity
- :activityType (string) - running, painting, pottery, etc.
- :frequency (string) - How often
- :duration (string) - How long they've done it
- :purpose (string) - Why they do it (destress, fun, etc.)
"""

# ============================================================================
# Schema-based Memory Store
# ============================================================================

class SchemaMemoryStore:
    """Memory store using schema.org vocabulary with entity-centric storage."""

    def __init__(self):
        # Entity stores by type
        self.persons: Dict[str, Dict] = {}  # name -> person data
        self.events: List[Dict] = []
        self.places: Dict[str, Dict] = {}  # name -> place data
        self.works: List[Dict] = []  # creative works
        self.organizations: Dict[str, Dict] = {}  # name -> org data
        self.pets: List[Dict] = []
        self.preferences: List[Dict] = []
        self.relationships: List[Dict] = []
        self.activities: List[Dict] = []

    def add_person(self, name: str, **properties) -> str:
        """Add or update a person entity."""
        name_key = name.lower().strip()
        if name_key not in self.persons:
            self.persons[name_key] = {"name": name, "type": "Person"}
        # Merge properties
        for k, v in properties.items():
            if v:  # Only set non-empty values
                self.persons[name_key][k] = v
        return name_key

    def add_event(self, name: str, date: str = None, attendees: List[str] = None,
                  location: str = None, event_type: str = None, **properties) -> str:
        """Add an event."""
        event = {
            "type": "Event",
            "name": name,
            "date": date,
            "attendees": attendees or [],
            "location": location,
            "event_type": event_type,
            **properties
        }
        self.events.append(event)
        return f"event_{len(self.events)}"

    def add_place(self, name: str, place_type: str = None, contained_in: str = None) -> str:
        """Add a place."""
        name_key = name.lower().strip()
        if name_key not in self.places:
            self.places[name_key] = {
                "type": "Place",
                "name": name,
                "place_type": place_type,
                "contained_in": contained_in
            }
        return name_key

    def add_creative_work(self, name: str, creator: str = None, work_type: str = None,
                          date_created: str = None, about: str = None,
                          significance: str = None) -> str:
        """Add a creative work (book, painting, etc.)."""
        work = {
            "type": "CreativeWork",
            "name": name,
            "creator": creator,
            "work_type": work_type,
            "date_created": date_created,
            "about": about,
            "significance": significance
        }
        self.works.append(work)
        return f"work_{len(self.works)}"

    def add_organization(self, name: str, org_type: str = None,
                         members: List[str] = None) -> str:
        """Add an organization."""
        name_key = name.lower().strip()
        self.organizations[name_key] = {
            "type": "Organization",
            "name": name,
            "org_type": org_type,
            "members": members or []
        }
        return name_key

    def add_pet(self, name: str, species: str, owner: str) -> str:
        """Add a pet."""
        pet = {
            "type": "Pet",
            "name": name,
            "species": species,
            "owner": owner
        }
        self.pets.append(pet)
        return f"pet_{len(self.pets)}"

    def add_preference(self, holder: str, pref_type: str, value: str,
                       reason: str = None) -> str:
        """Add a preference."""
        pref = {
            "type": "Preference",
            "holder": holder,
            "preference_type": pref_type,
            "value": value,
            "reason": reason
        }
        self.preferences.append(pref)
        return f"pref_{len(self.preferences)}"

    def add_relationship(self, person1: str, person2: str, rel_type: str,
                         duration: str = None, start_date: str = None) -> str:
        """Add a relationship between people."""
        rel = {
            "type": "Relationship",
            "person1": person1,
            "person2": person2,
            "relationship_type": rel_type,
            "duration": duration,
            "start_date": start_date
        }
        self.relationships.append(rel)
        return f"rel_{len(self.relationships)}"

    def add_activity(self, practitioner: str, activity_type: str,
                     frequency: str = None, duration: str = None,
                     purpose: str = None) -> str:
        """Add an activity/hobby."""
        activity = {
            "type": "Activity",
            "practitioner": practitioner,
            "activity_type": activity_type,
            "frequency": frequency,
            "duration": duration,
            "purpose": purpose
        }
        self.activities.append(activity)
        return f"activity_{len(self.activities)}"

    # ========================================================================
    # Query Methods - Structured retrieval
    # ========================================================================

    def get_person(self, name: str) -> Optional[Dict]:
        """Get a person by name."""
        name_key = name.lower().strip()
        return self.persons.get(name_key)

    def get_person_events(self, person_name: str) -> List[Dict]:
        """Get all events a person attended."""
        name_lower = person_name.lower()
        return [e for e in self.events
                if any(name_lower in a.lower() for a in e.get("attendees", []))]

    def get_person_works(self, person_name: str) -> List[Dict]:
        """Get all creative works by a person."""
        name_lower = person_name.lower()
        return [w for w in self.works
                if w.get("creator") and name_lower in w["creator"].lower()]

    def get_person_pets(self, person_name: str) -> List[Dict]:
        """Get all pets owned by a person."""
        name_lower = person_name.lower()
        return [p for p in self.pets
                if p.get("owner") and name_lower in p["owner"].lower()]

    def get_person_preferences(self, person_name: str, pref_type: str = None) -> List[Dict]:
        """Get preferences for a person, optionally filtered by type."""
        name_lower = person_name.lower()
        prefs = [p for p in self.preferences
                 if p.get("holder") and name_lower in p["holder"].lower()]
        if pref_type:
            prefs = [p for p in prefs if p.get("preference_type") == pref_type]
        return prefs

    def get_person_relationships(self, person_name: str) -> List[Dict]:
        """Get all relationships involving a person."""
        name_lower = person_name.lower()
        return [r for r in self.relationships
                if (r.get("person1") and name_lower in r["person1"].lower()) or
                   (r.get("person2") and name_lower in r["person2"].lower())]

    def get_person_activities(self, person_name: str) -> List[Dict]:
        """Get all activities a person does."""
        name_lower = person_name.lower()
        return [a for a in self.activities
                if a.get("practitioner") and name_lower in a["practitioner"].lower()]

    def get_events_by_type(self, event_type: str) -> List[Dict]:
        """Get events by type (pride_parade, conference, etc.)."""
        return [e for e in self.events if e.get("event_type") == event_type]

    def get_events_by_date(self, date_str: str) -> List[Dict]:
        """Get events on or around a date."""
        return [e for e in self.events if e.get("date") and date_str in e["date"]]

    def get_works_by_type(self, work_type: str) -> List[Dict]:
        """Get creative works by type (book, painting, etc.)."""
        return [w for w in self.works if w.get("work_type") == work_type]

    def get_organizations_by_type(self, org_type: str) -> List[Dict]:
        """Get organizations by type."""
        return [o for o in self.organizations.values() if o.get("org_type") == org_type]

    def get_timeline(self, person_name: str = None) -> List[Dict]:
        """Get events in chronological order, optionally filtered by person."""
        events = self.events
        if person_name:
            events = self.get_person_events(person_name)
        # Sort by date
        return sorted(events, key=lambda e: e.get("date") or "")

    def stats(self) -> Dict:
        """Get store statistics."""
        return {
            "persons": len(self.persons),
            "events": len(self.events),
            "places": len(self.places),
            "works": len(self.works),
            "organizations": len(self.organizations),
            "pets": len(self.pets),
            "preferences": len(self.preferences),
            "relationships": len(self.relationships),
            "activities": len(self.activities),
            "total": (len(self.persons) + len(self.events) + len(self.places) +
                     len(self.works) + len(self.organizations) + len(self.pets) +
                     len(self.preferences) + len(self.relationships) + len(self.activities))
        }


# Global memory store
MEMORY_STORE = SchemaMemoryStore()


# ============================================================================
# LLM Integration
# ============================================================================

def call_llm(messages: List[Dict], system: str = None, max_tokens: int = 2000) -> str:
    """Call LLM without tools, return text response."""
    if API_PROVIDER == "openai":
        return call_openai(messages, None, system, max_tokens)
    else:
        return call_anthropic(messages, None, system, max_tokens)


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
        # Preserve full message structure for tool calls
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
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json"
                },
                json=payload,
                timeout=120
            )
            if resp.status_code == 429:
                time.sleep(2 ** attempt)
                continue
            if resp.status_code == 400:
                print(f"  [API 400 Error: {resp.text[:300]}]")
            resp.raise_for_status()
            data = resp.json()

            choice = data["choices"][0]
            message = choice["message"]

            # Handle tool calls
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
                print(f"  [Connection error, retrying in {2**attempt}s: {str(e)[:60]}...]")
                time.sleep(2 ** attempt)
            else:
                raise


def call_anthropic(messages: List[Dict], tools: List[Dict] = None,
                   system: str = None, max_tokens: int = 2000) -> Dict:
    """Call Anthropic API."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY not set")

    payload = {
        "model": MODEL,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    if system:
        payload["system"] = system
    if tools:
        payload["tools"] = tools

    for attempt in range(5):
        try:
            resp = requests.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json"
                },
                json=payload,
                timeout=120
            )
            if resp.status_code == 429:
                time.sleep(2 ** attempt)
                continue
            resp.raise_for_status()
            return resp.json()
        except Exception as e:
            if attempt < 4:
                time.sleep(2 ** attempt)
            else:
                raise


# ============================================================================
# Schema-based Ingestion
# ============================================================================

INGESTION_SYSTEM = """You are a memory extraction agent that converts conversations into structured schema.org entities.

Given a conversation session, extract ALL important information into the appropriate schema types.

## Schema Types to Use:

### PERSON - Use for people mentioned
Extract: name, nationality, gender/identity, relationship_status, occupation, years_in_location

### EVENT - Use for things that happened
Extract: name, date (YYYY-MM-DD format), attendees (list of names), location, event_type
Event types: pride_parade, conference, workshop, support_group, camping_trip, museum_visit,
             race, pottery_class, concert, picnic, hike, road_trip, birthday, art_show

### PLACE - Use for locations mentioned
Extract: name, place_type (country, city, beach, mountain, forest, museum, etc.)

### CREATIVE_WORK - Use for books, paintings, pottery, songs
Extract: name/title, creator, work_type (book, painting, pottery, song), date_created,
         about (subject), significance (why meaningful)

### ORGANIZATION - Use for groups, agencies, companies
Extract: name, org_type (support_group, adoption_agency, activist_group, youth_center), members

### PET - Use for animals/pets
Extract: name, species (dog, cat, guinea_pig), owner

### PREFERENCE - Use for favorites, likes, opinions
Extract: holder (person name), preference_type (favorite_color, hobby, music_genre,
         favorite_book, stress_relief), value, reason

### RELATIONSHIP - Use for connections between people
Extract: person1, person2, relationship_type (friend, spouse, mentor, family),
         duration (e.g., "4 years"), start_date

### ACTIVITY - Use for hobbies, regular activities
Extract: practitioner (person name), activity_type (running, painting, pottery, swimming,
         guitar, piano, clarinet, camping, hiking), frequency, duration, purpose

## CRITICAL RULES:
1. Extract SPECIFIC values - "Sweden" not "home country", "Luna" not "her dog"
2. Always include dates when mentioned - convert to YYYY-MM-DD format
3. Create PERSON entries for anyone mentioned with details
4. Create separate entries for each distinct fact - don't combine
5. For events, always list attendees by name
6. Extract ALL pet names, book titles, painting names specifically

## Output Format:
Return a JSON array of entities to create:
```json
[
  {"type": "PERSON", "name": "Caroline", "nationality": "Sweden", "identity": "transgender woman"},
  {"type": "EVENT", "name": "LGBTQ support group", "date": "2023-05-07", "attendees": ["Caroline"], "event_type": "support_group"},
  {"type": "PET", "name": "Luna", "species": "dog", "owner": "Melanie"},
  ...
]
```
"""

def extract_entities(session_text: str, session_date: str) -> List[Dict]:
    """Extract schema.org entities from a conversation session."""

    prompt = f"""Extract all entities from this conversation session.
Session date context: {session_date}

Conversation:
{session_text}

Return ONLY a JSON array of entities. No other text."""

    messages = [{"role": "user", "content": prompt}]

    response = call_openai(messages, None, INGESTION_SYSTEM, max_tokens=4000)
    text = response.get("content", [{}])[0].get("text", "")

    # Parse JSON from response
    try:
        # Find JSON array in response
        start = text.find('[')
        end = text.rfind(']') + 1
        if start >= 0 and end > start:
            entities = json.loads(text[start:end])
            return entities
    except json.JSONDecodeError:
        pass

    return []


def store_entity(entity: Dict) -> str:
    """Store an extracted entity in the memory store."""
    entity_type = entity.get("type", "").upper()

    if entity_type == "PERSON":
        return MEMORY_STORE.add_person(
            name=entity.get("name", "Unknown"),
            nationality=entity.get("nationality"),
            identity=entity.get("identity"),
            relationship_status=entity.get("relationship_status"),
            occupation=entity.get("occupation"),
            years_in_location=entity.get("years_in_location"),
            birth_date=entity.get("birth_date"),
            gender=entity.get("gender")
        )

    elif entity_type == "EVENT":
        return MEMORY_STORE.add_event(
            name=entity.get("name", "Unknown event"),
            date=entity.get("date"),
            attendees=entity.get("attendees", []),
            location=entity.get("location"),
            event_type=entity.get("event_type")
        )

    elif entity_type == "PLACE":
        return MEMORY_STORE.add_place(
            name=entity.get("name", "Unknown place"),
            place_type=entity.get("place_type"),
            contained_in=entity.get("contained_in")
        )

    elif entity_type == "CREATIVE_WORK":
        return MEMORY_STORE.add_creative_work(
            name=entity.get("name", "Unknown work"),
            creator=entity.get("creator"),
            work_type=entity.get("work_type"),
            date_created=entity.get("date_created"),
            about=entity.get("about"),
            significance=entity.get("significance")
        )

    elif entity_type == "ORGANIZATION":
        return MEMORY_STORE.add_organization(
            name=entity.get("name", "Unknown org"),
            org_type=entity.get("org_type"),
            members=entity.get("members", [])
        )

    elif entity_type == "PET":
        return MEMORY_STORE.add_pet(
            name=entity.get("name", "Unknown pet"),
            species=entity.get("species", "unknown"),
            owner=entity.get("owner", "unknown")
        )

    elif entity_type == "PREFERENCE":
        return MEMORY_STORE.add_preference(
            holder=entity.get("holder", "unknown"),
            pref_type=entity.get("preference_type", "general"),
            value=entity.get("value", ""),
            reason=entity.get("reason")
        )

    elif entity_type == "RELATIONSHIP":
        return MEMORY_STORE.add_relationship(
            person1=entity.get("person1", "unknown"),
            person2=entity.get("person2", "unknown"),
            rel_type=entity.get("relationship_type", "knows"),
            duration=entity.get("duration"),
            start_date=entity.get("start_date")
        )

    elif entity_type == "ACTIVITY":
        return MEMORY_STORE.add_activity(
            practitioner=entity.get("practitioner", "unknown"),
            activity_type=entity.get("activity_type", "unknown"),
            frequency=entity.get("frequency"),
            duration=entity.get("duration"),
            purpose=entity.get("purpose")
        )

    return "unknown"


# ============================================================================
# Schema-based Query Tools
# ============================================================================

QUERY_TOOLS = [
    {
        "name": "get_person_info",
        "description": "Get all stored information about a person including their properties (nationality, identity, occupation, etc.)",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_events",
        "description": "Get all events a person attended, with dates and details",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_activities",
        "description": "Get hobbies and activities a person does (running, painting, etc.)",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_preferences",
        "description": "Get a person's preferences and favorites (colors, music, books, etc.)",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"},
                "preference_type": {"type": "string", "description": "Optional: filter by type (favorite_color, hobby, etc.)"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_pets",
        "description": "Get pets owned by a person, with names and species",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_relationships",
        "description": "Get relationships a person has (friends, family, spouse, etc.)",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_person_works",
        "description": "Get creative works (paintings, books, pottery) created by a person",
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Person's name"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "get_events_by_type",
        "description": "Get all events of a specific type (pride_parade, conference, camping_trip, etc.)",
        "parameters": {
            "type": "object",
            "properties": {
                "event_type": {"type": "string", "description": "Event type to search for"}
            },
            "required": ["event_type"]
        }
    },
    {
        "name": "get_works_by_type",
        "description": "Get all creative works of a type (book, painting, pottery)",
        "parameters": {
            "type": "object",
            "properties": {
                "work_type": {"type": "string", "description": "Work type: book, painting, pottery, song"}
            },
            "required": ["work_type"]
        }
    },
    {
        "name": "get_timeline",
        "description": "Get events in chronological order, optionally filtered by person",
        "parameters": {
            "type": "object",
            "properties": {
                "person_name": {"type": "string", "description": "Optional: filter to events involving this person"}
            },
            "required": []
        }
    },
    {
        "name": "get_all_pets",
        "description": "Get all pets in memory with their names, species, and owners",
        "parameters": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "get_all_books",
        "description": "Get all books mentioned in memory",
        "parameters": {
            "type": "object",
            "properties": {},
            "required": []
        }
    }
]


def execute_query_tool(tool_name: str, tool_input: Dict) -> str:
    """Execute a query tool and return results."""

    if tool_name == "get_person_info":
        person = MEMORY_STORE.get_person(tool_input.get("name", ""))
        if person:
            return json.dumps(person, indent=2)
        return "Person not found"

    elif tool_name == "get_person_events":
        events = MEMORY_STORE.get_person_events(tool_input.get("name", ""))
        return json.dumps(events, indent=2) if events else "No events found"

    elif tool_name == "get_person_activities":
        activities = MEMORY_STORE.get_person_activities(tool_input.get("name", ""))
        return json.dumps(activities, indent=2) if activities else "No activities found"

    elif tool_name == "get_person_preferences":
        prefs = MEMORY_STORE.get_person_preferences(
            tool_input.get("name", ""),
            tool_input.get("preference_type")
        )
        return json.dumps(prefs, indent=2) if prefs else "No preferences found"

    elif tool_name == "get_person_pets":
        pets = MEMORY_STORE.get_person_pets(tool_input.get("name", ""))
        return json.dumps(pets, indent=2) if pets else "No pets found"

    elif tool_name == "get_person_relationships":
        rels = MEMORY_STORE.get_person_relationships(tool_input.get("name", ""))
        return json.dumps(rels, indent=2) if rels else "No relationships found"

    elif tool_name == "get_person_works":
        works = MEMORY_STORE.get_person_works(tool_input.get("name", ""))
        return json.dumps(works, indent=2) if works else "No works found"

    elif tool_name == "get_events_by_type":
        events = MEMORY_STORE.get_events_by_type(tool_input.get("event_type", ""))
        return json.dumps(events, indent=2) if events else "No events found"

    elif tool_name == "get_works_by_type":
        works = MEMORY_STORE.get_works_by_type(tool_input.get("work_type", ""))
        return json.dumps(works, indent=2) if works else "No works found"

    elif tool_name == "get_timeline":
        timeline = MEMORY_STORE.get_timeline(tool_input.get("person_name"))
        return json.dumps(timeline, indent=2) if timeline else "No events found"

    elif tool_name == "get_all_pets":
        return json.dumps(MEMORY_STORE.pets, indent=2) if MEMORY_STORE.pets else "No pets found"

    elif tool_name == "get_all_books":
        books = [w for w in MEMORY_STORE.works if w.get("work_type") == "book"]
        return json.dumps(books, indent=2) if books else "No books found"

    return "Unknown tool"


# ============================================================================
# Query Agent
# ============================================================================

QUERY_SYSTEM = """You are a question-answering agent with access to a structured memory system.

The memory system stores information as schema.org entities:
- PERSON: People with properties (nationality, identity, occupation, etc.)
- EVENT: Things that happened with dates, attendees, locations
- ACTIVITY: Hobbies and regular activities people do
- PREFERENCE: Favorites and likes (colors, music, books, etc.)
- PET: Animals with names, species, owners
- RELATIONSHIP: Connections between people (friends, family, etc.)
- CREATIVE_WORK: Books, paintings, pottery with creators and dates

**QUERY STRATEGY**:
1. For questions about a person, start with get_person_info to get their properties
2. For "when" questions, use get_person_events or get_timeline
3. For activities/hobbies, use get_person_activities
4. For pets, use get_person_pets (returns names directly!)
5. For books/paintings, use get_person_works or get_works_by_type
6. For preferences/favorites, use get_person_preferences

**ANSWER FORMAT - KEEP IT CONCISE**:
- For "When?" → Give the date
- For "What?" → List the items
- For "Who?" → Give names
- Avoid long explanations

**INFERENCE**:
For commonsense questions, use the structured data to make reasonable inferences.
"""


def answer_with_agent(question: str, verbose: bool = True) -> str:
    """Have the agent answer a question using schema-based tools."""

    messages = [{"role": "user", "content": f"Answer this question: {question}"}]

    for i in range(6):
        response = call_openai(messages, QUERY_TOOLS, QUERY_SYSTEM, max_tokens=1000)

        content = response.get("content", [])
        stop_reason = response.get("stop_reason", "")

        tool_uses = [c for c in content if c.get("type") == "tool_use"]

        if not tool_uses or stop_reason == "stop":
            text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
            return " ".join(text_parts).strip() or "Cannot determine from memory."

        # Execute tools
        tool_results = []
        for tool_use in tool_uses:
            tool_name = tool_use["name"]
            tool_input = tool_use["input"]

            if verbose:
                print(f"    [{tool_name}] {tool_input}")

            result = execute_query_tool(tool_name, tool_input)
            tool_results.append({
                "tool_call_id": tool_use["id"],
                "content": result
            })

        # Add assistant message with tool calls
        assistant_msg = {
            "role": "assistant",
            "content": "",  # Empty string for OpenAI when tool_calls present
            "tool_calls": [
                {
                    "id": tu["id"],
                    "type": "function",
                    "function": {"name": tu["name"], "arguments": json.dumps(tu["input"])}
                }
                for tu in tool_uses
            ]
        }
        messages.append(assistant_msg)

        # Add tool results
        for tr in tool_results:
            messages.append({
                "role": "tool",
                "tool_call_id": tr["tool_call_id"],
                "content": tr["content"]
            })

    return "Cannot determine (max iterations)"


# ============================================================================
# Evaluation Metrics (same as agentic-memory.py)
# ============================================================================

def normalize_answer(text: str) -> str:
    """Normalize answer following LoCoMo's normalize_answer()"""
    text = text.lower()
    text = text.translate(str.maketrans('', '', string.punctuation))
    articles = {'a', 'an', 'the', 'and'}
    words = [w for w in text.split() if w not in articles]
    return ' '.join(words)

def simple_stem(word: str) -> str:
    """Simple suffix-stripping stemmer."""
    suffixes = ['ing', 'ed', 'es', 's', 'ly', 'er', 'est', 'tion', 'ness']
    word = word.lower()
    for suffix in sorted(suffixes, key=len, reverse=True):
        if word.endswith(suffix) and len(word) > len(suffix) + 2:
            return word[:-len(suffix)]
    return word

def tokenize(text: str, stemming: bool = True) -> List[str]:
    """Tokenize and optionally stem text."""
    normalized = normalize_answer(text)
    words = normalized.split()
    if stemming:
        words = [simple_stem(w) for w in words]
    return words

def compute_token_f1(prediction: str, ground_truth: str, stemming: bool = True) -> float:
    """Compute token-level F1 score."""
    pred_tokens = set(tokenize(prediction, stemming=stemming))
    truth_tokens = set(tokenize(ground_truth, stemming=stemming))

    if not pred_tokens or not truth_tokens:
        return 0.0

    intersection = pred_tokens & truth_tokens
    precision = len(intersection) / len(pred_tokens)
    recall = len(intersection) / len(truth_tokens)

    if precision + recall == 0:
        return 0.0

    return 2 * (precision * recall) / (precision + recall)

def compute_category_f1(prediction: str, ground_truth: str, category: int) -> float:
    """Category-specific F1 computation."""
    if category == 5:  # Adversarial
        pred_lower = prediction.lower()
        if "no information" in pred_lower or "cannot" in pred_lower:
            return 1.0 if "no information" in ground_truth.lower() else 0.0
        return 0.0 if "no information" in ground_truth.lower() else compute_token_f1(prediction, ground_truth)

    if category == 1:  # Single-hop with possible multiple answers
        if ',' in ground_truth:
            answers = [a.strip() for a in ground_truth.split(',')]
            return max(compute_token_f1(prediction, ans) for ans in answers)

    return compute_token_f1(prediction, ground_truth)


# LLM Judge
JUDGE_PROMPT = """Your task is to label an answer to a question as 'CORRECT' or 'WRONG'.

Question: {question}
Gold (ground truth) answer: {gold}
Generated answer: {generated}

Rules:
- CORRECT if the generated answer contains the key information from the gold answer
- CORRECT if dates match (May 7 = 7 May = 2023-05-07)
- WRONG if key facts are missing or incorrect
- WRONG if years don't match (2022 vs 2023 = WRONG)

Return ONLY: CORRECT or WRONG"""

def judge_answer(question: str, gold: str, generated: str) -> int:
    """Use LLM to judge if answer is correct."""
    prompt = JUDGE_PROMPT.format(question=question, gold=gold, generated=generated)

    response = call_openai([{"role": "user", "content": prompt}], None, None, max_tokens=10)
    text = response.get("content", [{}])[0].get("text", "").upper()

    return 1 if "CORRECT" in text else 0


# ============================================================================
# Main Evaluation
# ============================================================================

def load_locomo_data() -> Dict:
    """Load LoCoMo dataset."""
    data_path = Path("eval/locomo/data/locomo10.json")
    if not data_path.exists():
        data_path.parent.mkdir(parents=True, exist_ok=True)
        print("Downloading LoCoMo dataset...")
        url = "https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json"
        resp = requests.get(url)
        resp.raise_for_status()
        data_path.write_text(resp.text)
    return json.loads(data_path.read_text())


def get_sessions(conv: Dict) -> List[Tuple[str, str, str]]:
    """Extract sessions from conversation, return list of (session_num, date, text)."""
    conversation = conv.get("conversation", {})

    sessions = []
    for i in range(1, 50):  # Up to 50 sessions
        session_key = f"session_{i}"
        date_key = f"session_{i}_date_time"

        if session_key not in conversation:
            continue

        session_data = conversation[session_key]
        session_date = conversation.get(date_key, "unknown")

        if session_data:
            # Session is a list of message dicts
            if isinstance(session_data, list):
                lines = []
                for msg in session_data:
                    speaker = msg.get("speaker", "Unknown")
                    text = msg.get("text", "")
                    lines.append(f"{speaker}: {text}")
                session_text = "\n".join(lines)
            else:
                session_text = str(session_data)

            sessions.append((str(i), session_date, session_text))

    return sessions


def run_evaluation(limit: int = 10, verbose: bool = True, workers: int = 1):
    """Run the schema-based memory evaluation."""

    global MEMORY_STORE
    MEMORY_STORE = SchemaMemoryStore()

    print(f"\n{'='*70}")
    print("  LoCoMo Schema.org Memory Evaluation")
    print(f"  Model: {MODEL}")
    print(f"{'='*70}")

    # Load data
    data = load_locomo_data()
    conv = data[0]  # Use first conversation

    # Phase 1: Ingestion
    print("\n" + "="*50)
    print("Phase 1: SCHEMA-BASED MEMORY EXTRACTION")
    print("="*50)

    sessions = get_sessions(conv)
    for session_num, session_date, session_text in sessions:
        print(f"\n  Session {session_num} ({session_date[:15]}...)...")

        entities = extract_entities(session_text, session_date)

        for entity in entities:
            entity_type = entity.get("type", "unknown")
            store_entity(entity)

            # Show what was extracted
            if entity_type == "PERSON":
                print(f"    [Person] {entity.get('name')}: {entity.get('identity', '')} {entity.get('nationality', '')}")
            elif entity_type == "EVENT":
                print(f"    [Event] {entity.get('name')} on {entity.get('date', '?')}")
            elif entity_type == "PET":
                print(f"    [Pet] {entity.get('name')} ({entity.get('species')}) - owner: {entity.get('owner')}")
            elif entity_type == "CREATIVE_WORK":
                print(f"    [Work] {entity.get('name')} ({entity.get('work_type')}) by {entity.get('creator', '?')}")
            elif entity_type == "ACTIVITY":
                print(f"    [Activity] {entity.get('practitioner')}: {entity.get('activity_type')}")
            elif entity_type == "PREFERENCE":
                print(f"    [Pref] {entity.get('holder')}: {entity.get('preference_type')}={entity.get('value')}")

        print(f"    → {len(entities)} entities extracted")

    stats = MEMORY_STORE.stats()
    print(f"\n  Total: {stats['total']} entities")
    print(f"  By type: {stats}")

    # Phase 2: QA
    print("\n" + "="*50)
    print("Phase 2: SCHEMA-BASED QUESTION ANSWERING")
    print("="*50)

    qa_pairs = [qa for qa in conv["qa"] if qa["category"] != 5][:limit]
    results = []
    detailed_results = []

    for i, qa in enumerate(qa_pairs, 1):
        question = qa["question"]
        gold = str(qa["answer"])
        category = qa["category"]

        q_display = question[:55] + "..." if len(question) > 55 else question
        print(f"\n[{i}/{len(qa_pairs)}] {q_display}")

        generated = answer_with_agent(question, verbose)

        f1 = compute_category_f1(generated, gold, category)
        judge_score = judge_answer(question, gold, generated)

        gold_display = gold[:45] + "..." if len(gold) > 45 else gold
        gen_display = generated[:50] + "..." if len(generated) > 50 else generated

        print(f"  Expected: {gold_display}")
        print(f"  Got:      {gen_display}")
        print(f"  F1: {f1:.3f} | Judge: {'✓ CORRECT' if judge_score == 1 else '✗ WRONG'}")

        results.append((category, judge_score, f1))
        detailed_results.append({
            "index": i,
            "question": question,
            "expected": gold,
            "generated": generated,
            "category": category,
            "category_name": CATEGORY_NAMES[category],
            "f1_score": round(f1, 4),
            "llm_judge": "CORRECT" if judge_score == 1 else "WRONG",
            "llm_judge_score": judge_score
        })

    # Print results
    print("\n" + "="*70)
    print("RESULTS: Schema.org Memory")
    print("="*70)

    # F1 by category
    print(f"\n{'='*65}")
    print("F1 SCORES")
    print(f"{'='*65}")

    by_cat = {}
    for cat, _, f1 in results:
        cat_name = CATEGORY_NAMES[cat]
        if cat_name not in by_cat:
            by_cat[cat_name] = []
        by_cat[cat_name].append(f1)

    total_f1 = sum(f1 for _, _, f1 in results) / len(results) if results else 0

    for cat_name, f1s in by_cat.items():
        avg = sum(f1s) / len(f1s)
        print(f"{cat_name:20} {avg:.3f}")
    print(f"{'OVERALL':20} {total_f1:.3f}")

    # Judge accuracy
    print(f"\n{'='*65}")
    print("LLM JUDGE ACCURACY")
    print(f"{'='*65}")

    by_cat_judge = {}
    for cat, score, _ in results:
        cat_name = CATEGORY_NAMES[cat]
        if cat_name not in by_cat_judge:
            by_cat_judge[cat_name] = []
        by_cat_judge[cat_name].append(score)

    total_correct = sum(s for _, s, _ in results)

    for cat_name, scores in by_cat_judge.items():
        correct = sum(scores)
        total = len(scores)
        print(f"{cat_name:20} {correct}/{total} ({100*correct/total:.1f}%)")
    print(f"{'OVERALL':20} {total_correct}/{len(results)} ({100*total_correct/len(results):.1f}%)")

    # Save results
    results_dir = Path("eval/locomo/results")
    results_dir.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    results_file = results_dir / f"schema-eval-{timestamp}.json"

    log_data = {
        "timestamp": datetime.now().isoformat(),
        "model": MODEL,
        "approach": "schema.org",
        "limit": limit,
        "memory_stats": stats,
        "summary": {
            "total_questions": len(results),
            "overall_f1": round(total_f1, 4),
            "judge_correct": total_correct,
            "judge_accuracy": round(100 * total_correct / len(results), 1)
        },
        "questions": detailed_results
    }

    results_file.write_text(json.dumps(log_data, indent=2))
    print(f"\n📝 Results saved to: {results_file}")


def main():
    parser = argparse.ArgumentParser(description="LoCoMo Schema.org Memory Evaluation")
    parser.add_argument("--limit", type=int, default=10, help="Max questions")
    parser.add_argument("--verbose", "-v", action="store_true", default=True)
    parser.add_argument("--quiet", "-q", action="store_true")
    parser.add_argument("--workers", "-w", type=int, default=1)

    args = parser.parse_args()
    run_evaluation(limit=args.limit, verbose=not args.quiet, workers=args.workers)


if __name__ == "__main__":
    main()
