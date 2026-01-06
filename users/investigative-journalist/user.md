# Investigative Journalist / Researcher

## Identity

**Name**: The Investigator
**Type**: Journalist or independent researcher building stories from sources
**Graph**: `meld:graph/investigation/{investigation-id}`, `meld:graph/sources/{journalist-id}`

## Interaction Model

```
┌──────────────┐      natural       ┌──────────────┐      meld CLI      ┌──────────────┐
│  Journalist  │ ◄─── language ───► │   Agent      │ ◄───────────────► │  Meld Graph  │
│   (Amara)    │                    │  (Claude)    │                    │              │
│              │                    │              │                    │  sources,    │
│  discusses   │                    │  tracks,     │                    │  claims,     │
│  sources,    │                    │  connects,   │                    │  evidence,   │
│  leads,      │                    │  verifies,   │                    │  connections │
│  evidence    │                    │  protects    │                    │  timelines   │
└──────────────┘                    └──────────────┘                    └──────────────┘

The journalist discusses their investigation naturally. The agent
builds a knowledge graph of sources, claims, and connections—with
verification status and source protection built in.
```

## Who They Are

Amara is an investigative journalist at a regional newspaper. She covers government accountability, corporate malfeasance, and occasionally organized crime. Her investigations unfold over months—sometimes years. She juggles dozens of sources, hundreds of documents, and thousands of facts that may or may not connect.

She works with an AI agent throughout her investigation. She talks through what sources told her, discusses documents she's reviewing, and thinks aloud about connections. **She never interacts with meld directly**—she just has conversations with her agent, and it remembers everything.

**The problem today**: Investigations are chaos. Notes scattered across notebooks, documents in folders, source conversations in memory. When she returns to a story after two weeks on another assignment, she's lost. When a source mentions a name that appeared in a document three months ago, she might not make the connection.

**The solution**: Meld gives her agent a persistent investigation graph. Every source, every claim, every document, every connection—tracked and linked. When a name surfaces again, her agent remembers where it appeared before.

## Daily Reality

### Morning: Source Call

Amara has a call with a source inside the city planning department. The source mentions that the mayor's brother-in-law got a no-bid contract for a construction project. She discusses the call with her agent:

> "Just got off the phone with my planning department source. They say the mayor's brother-in-law—I think his name is Victor Oduya—got a $2.3 million contract for the downtown plaza renovation. No competitive bidding. Source says the contract was routed through a shell company called Lakeshore Holdings."

Her agent records this: the source (anonymized), the claims (unverified), the entities (Victor Oduya, Lakeshore Holdings, the mayor), and the connections. Single-source claim, marked accordingly.

### Midday: Document Review

Amara obtained city procurement records through a FOIA request. She's reviewing them with her agent:

> "Looking at the procurement records now. I see a contract for 'Downtown Plaza Phase 2 Renovation' dated March 15, 2025. Awarded to Lakeshore Holdings LLC for $2,340,000. The contract officer signature is illegible. No bid documents attached."

Her agent notes: this corroborates the source's claim. The amount matches. The entity (Lakeshore Holdings) is confirmed in documents. Verification status upgrades from "single source" to "source + documents."

### Afternoon: Connection Mapping

Amara is trying to understand the corporate structure:

> "Can you map out what we know about Lakeshore Holdings? Who's connected to it, what contracts they have, and how they tie back to the mayor?"

Her agent queries the graph and shows: Lakeshore Holdings → contract for plaza renovation → alleged connection to Victor Oduya (source claim, unverified) → Victor Oduya is mayor's brother-in-law (public record). The gap: no document yet proving Victor Oduya controls Lakeshore Holdings.

### Evening: Following a Thread

While reviewing old notes, Amara's agent surfaces a connection:

> "I noticed something while you were reviewing today's documents. Three months ago, your source at the licensing bureau mentioned a company called 'Lakeshore Properties' that had unusual permit approvals. Different name, but similar. Want me to check if there's a connection?"

This is the value: connections Amara might have missed because the names were slightly different, mentioned months apart.

## Investigation Knowledge Architecture

```
meld:graph/investigation/city-hall-contracts
│
├── meld:entity/person/victor-oduya
│   ├── [rdfs:label] "Victor Oduya"
│   ├── [meld:role] "Mayor's brother-in-law"
│   ├── [meld:roleSource] meld:evidence/public-records-marriage
│   └── [meld:allegedConnection] meld:entity/org/lakeshore-holdings
│
├── meld:entity/org/lakeshore-holdings
│   ├── [rdfs:label] "Lakeshore Holdings LLC"
│   ├── [meld:type] "Shell company (alleged)"
│   ├── [meld:contract] meld:evidence/contract-plaza-renovation
│   └── [meld:possibleAlias] meld:entity/org/lakeshore-properties
│
├── meld:claim/no-bid-contract
│   ├── [rdfs:label] "Plaza contract awarded without competitive bidding"
│   ├── [meld:verificationStatus] "corroborated"
│   ├── [meld:source] meld:source/planning-insider (confidential)
│   ├── [meld:evidence] meld:evidence/contract-plaza-renovation
│   └── [meld:confidence] 0.85
│
├── meld:claim/oduya-controls-lakeshore
│   ├── [rdfs:label] "Victor Oduya controls Lakeshore Holdings"
│   ├── [meld:verificationStatus] "single-source"
│   ├── [meld:source] meld:source/planning-insider (confidential)
│   ├── [meld:confidence] 0.4
│   └── [meld:needed] "Corporate registration documents, financial records"
│
├── meld:evidence/contract-plaza-renovation
│   ├── [rdfs:label] "Downtown Plaza Phase 2 Contract"
│   ├── [meld:documentType] "City procurement record"
│   ├── [meld:obtainedVia] "FOIA request"
│   ├── [dcterms:date] "2025-03-15"
│   ├── [meld:amount] "$2,340,000"
│   └── [meld:corroborates] meld:claim/no-bid-contract
│
└── meld:source/planning-insider
    ├── [rdfs:label] "Source A" (anonymized in graph)
    ├── [meld:reliability] "high"
    ├── [meld:accessLevel] "Direct knowledge"
    ├── [meld:relationship] "Current employee"
    └── [prov:wasAttributedTo] REDACTED (encrypted separately)
```

## Goals

### Primary Goal: Verification Tracking

Journalism lives and dies by verification. A claim from one source is a lead. The same claim corroborated by documents is a fact. Amara needs her agent to track verification status rigorously.

**Success looks like:**

**What Amara says:**
> "What do we actually *know* versus what we've only *heard*?"

**What the agent does (invisible):**
```bash
meld query sparql "SELECT ?claim ?status ?sourceCount ?evidenceCount WHERE {
  ?claim a meld:Claim .
  ?claim meld:verificationStatus ?status .
  {
    SELECT ?claim (COUNT(DISTINCT ?source) as ?sourceCount) WHERE {
      ?claim meld:source ?source
    } GROUP BY ?claim
  }
  {
    SELECT ?claim (COUNT(DISTINCT ?evidence) as ?evidenceCount) WHERE {
      ?claim meld:evidence ?evidence
    } GROUP BY ?claim
  }
}"
```

**What Amara sees:**
> "Here's our verification status for the city hall investigation:
>
> **Confirmed (multiple sources + documents):**
> - Lakeshore Holdings received $2.34M plaza contract (source + procurement records)
> - Contract had no competitive bidding (source + missing bid docs)
>
> **Corroborated (2+ sources OR source + partial docs):**
> - Mayor intervened in contract approval process (2 sources, no documents yet)
>
> **Single-source (leads to verify):**
> - Victor Oduya controls Lakeshore Holdings
> - Kickback payments to campaign fund
> - Second shell company for public works contracts
>
> **Unverified claims from anonymous tips:**
> - 3 claims from tip line, no corroboration
>
> The Oduya-Lakeshore connection is the key gap. If we can document that, the story comes together."

---

### Secondary Goal: Connection Discovery

Investigations uncover networks—people connected to companies connected to contracts connected to politicians. Amara needs her agent to see connections she might miss.

**Success looks like:**

**What Amara says:**
> "I keep seeing the name 'Meridian Consulting' in these records. Do we know anything about them?"

**What the agent does (invisible):**
```bash
# Search for any mention of Meridian
meld query sparql "SELECT ?node ?property ?value WHERE {
  ?node ?property ?value .
  FILTER(CONTAINS(LCASE(STR(?value)), 'meridian'))
}"

# Check for entity
meld node get "meld:entity/org/meridian-consulting" --include-backlinks
```

**What Amara sees:**
> "Meridian Consulting appears in three places in your investigation:
>
> 1. **Licensing bureau source (4 months ago)**: Mentioned as 'consultant' on Lakeshore Properties permit applications
>
> 2. **Campaign finance records (2 months ago)**: $15,000 donation to mayor's re-election fund from 'Meridian Consulting LLC'
>
> 3. **Today's procurement records**: Listed as 'project management consultant' on the plaza renovation contract
>
> I don't have corporate records for Meridian yet. But if they're consulting for Lakeshore *and* donating to the mayor *and* getting paid on city contracts—that's a pattern worth investigating.
>
> Want me to add 'Obtain Meridian Consulting corporate registration' to the investigation's open questions?"

---

### Tertiary Goal: Source Protection

Sources are sacred. Some sources must remain confidential—their identity protected even in Amara's notes. Her agent must understand source protection levels.

**Success looks like:**

**What Amara says:**
> "I need to share this investigation with my editor. What can he see?"

**What the agent does (invisible):**
```bash
# Check capability for editor
meld cap attenuate --cap "meld:cap/investigation-full" \
  --exclude-graphs "meld:graph/sources/amara-confidential" \
  --permissions read
```

**What Amara sees:**
> "Your editor can see:
> - All claims, evidence, and entity connections
> - Source reliability ratings (high/medium/low)
> - Source access levels (direct knowledge, secondhand, etc.)
>
> Your editor **cannot** see:
> - Confidential source identities (Source A, Source B, etc.)
> - Source contact information
> - Meeting dates/locations with confidential sources
>
> The planning department source will appear as 'Source A - high reliability, direct knowledge, current employee.' Their name stays protected.
>
> Want me to generate an editor-safe investigation summary?"

## Interaction Patterns (Journalist → Agent → Meld)

### Recording Source Information

**What Amara says:**
> "Had coffee with my source at the planning department this morning. Off the record. They said the mayor personally called the procurement director to push the Lakeshore contract through. They were in the room when the call happened. Also mentioned there might be a second company, something about public works contracts, but they didn't have details."

**What the agent does (invisible):**
```bash
# Record the source interaction (protected graph)
meld node create --graph "meld:graph/sources/amara-confidential" \
  --type source-meeting \
  --property "date=2026-01-15" \
  --property "source=planning-insider" \
  --property "terms=off the record" \
  --property "location=REDACTED"

# Record claims from this meeting (investigation graph, anonymized)
meld node create --type claim \
  --property "label=Mayor personally intervened in Lakeshore contract" \
  --property "detail=Called procurement director to push contract through" \
  --property "source_access=direct witness (present in room)" \
  --link "meld:source:meld:source/planning-insider" \
  --link "meld:verificationStatus:single-source" \
  --link "meld:confidence:0.6"

meld node create --type lead \
  --property "label=Possible second shell company for public works" \
  --property "detail=Source mentioned but had no specifics" \
  --link "meld:source:meld:source/planning-insider" \
  --link "meld:verificationStatus:unverified-lead"

# Update source reliability (they were an eyewitness)
meld node update "meld:source/planning-insider" \
  --property "last_contact=2026-01-15" \
  --property "access_quality=direct witness on key claim"
```

**What Amara sees:**
> "Recorded. Key new claims:
>
> 1. **Mayor intervened in Lakeshore contract** - Source was present when the mayor called procurement. This is direct witness testimony, stronger than hearsay. Currently single-source—we need corroboration.
>
> 2. **Second shell company (lead)** - Vague but worth following. I'll add it to open questions.
>
> Your planning source has now provided direct witness testimony. That upgrades their value significantly. Anything else from the conversation?"

---

### Reviewing Documents

**What Amara says:**
> "I'm looking at the corporate registration for Lakeshore Holdings. It was incorporated in Delaware in 2023. Registered agent is 'Corporate Services Inc.'—looks like a standard anonymizing service. But the annual report lists a business address at 1847 Lake Street, which is interesting."

**What the agent does (invisible):**
```bash
# Record the evidence
meld node create --type evidence \
  --property "label=Lakeshore Holdings LLC - Delaware Registration" \
  --property "document_type=Corporate registration" \
  --property "date_incorporated=2023" \
  --property "registered_agent=Corporate Services Inc." \
  --property "business_address=1847 Lake Street" \
  --property "obtained_via=Public records search" \
  --link "skos:related:meld:entity/org/lakeshore-holdings"

# Check if that address appears anywhere else
meld query sparql "SELECT ?node ?context WHERE {
  ?node ?p ?value .
  FILTER(CONTAINS(STR(?value), '1847 Lake'))
  ?node rdfs:label ?context
}"

# Found: this address appeared before!
```

**What Amara sees:**
> "Interesting find—1847 Lake Street appeared once before in your notes:
>
> **Three months ago**: Your licensing bureau source mentioned that Lakeshore Properties (the similar-named company) listed '1847 Lake St' on their permit applications.
>
> This strengthens the connection between Lakeshore Holdings and Lakeshore Properties. Same address, similar names—likely related entities or intentional obfuscation.
>
> I've recorded the corporate registration as evidence. Want me to search for other businesses registered at that address?"

---

### Building a Timeline

**What Amara says:**
> "I'm trying to understand the sequence of events. Can you build me a timeline of everything related to the plaza contract?"

**What the agent does (invisible):**
```bash
meld query sparql "SELECT ?event ?date ?description WHERE {
  ?event skos:related <meld:investigation/city-hall-contracts> .
  ?event dcterms:date ?date .
  ?event rdfs:label ?description
} ORDER BY ?date"
```

**What Amara sees:**
> "Timeline for plaza contract investigation:
>
> | Date | Event | Source |
> |------|-------|--------|
> | Jan 2023 | Lakeshore Holdings incorporated in Delaware | Corporate records |
> | Oct 2024 | Mayor's re-election campaign begins | Public record |
> | Nov 2024 | Meridian Consulting donates $15K to mayor | Campaign finance |
> | Feb 2025 | Plaza renovation project announced | City press release |
> | Mar 2025 | Lakeshore Holdings awarded $2.34M contract | Procurement records |
> | Mar 2025 | Mayor calls procurement director (alleged) | Source A |
> | Apr 2025 | Construction begins | Public record |
> | Jul 2025 | Your source first mentions Lakeshore | Your notes |
>
> **Notable:** The company was incorporated almost two years before getting the contract—suggests planning, not opportunism. Meridian's donation came just before the project was announced. The mayor's alleged call happened around contract award time.
>
> Want me to add the Lakeshore Properties permit timeline to see if those dates align?"

---

### Preparing to Publish

**What Amara says:**
> "I think we're close to publishable. What's the strongest version of this story we can tell with fully verified facts?"

**What the agent does (invisible):**
```bash
# Query only confirmed/corroborated claims
meld query sparql "SELECT ?claim ?evidence ?sourceCount WHERE {
  ?claim a meld:Claim .
  ?claim meld:verificationStatus ?status .
  FILTER(?status IN ('confirmed', 'corroborated'))
  ?claim meld:evidence ?evidence .
  {
    SELECT ?claim (COUNT(?source) as ?sourceCount) WHERE {
      ?claim meld:source ?source
    } GROUP BY ?claim
  }
}"
```

**What Amara sees:**
> "Here's what you can confidently publish:
>
> **Fully documented:**
> - Lakeshore Holdings received $2.34M city contract for plaza renovation
> - No competitive bidding occurred (no bid documents exist)
> - Lakeshore Holdings shares address with Lakeshore Properties
> - Meridian Consulting received fees on the contract AND donated to mayor's campaign
>
> **Corroborated but sensitive:**
> - Mayor intervened in contract approval (2 sources, no documents)
> - Pattern suggests coordination between Lakeshore, Meridian, and mayor's office
>
> **Not yet publishable:**
> - Victor Oduya's control of Lakeshore Holdings (single source, no docs)
> - Kickback allegations (single source)
>
> **My recommendation:** You have a strong accountability story about no-bid contracts and donor/contractor overlap. The Oduya angle makes it personal corruption rather than just cronyism—but you need the corporate records to prove it.
>
> Want me to draft an outline for the story we *can* publish while you work on the Oduya documentation?"

## Capability Model for Journalism

```
Capability Hierarchy:

meld:cap/journalist-full (Amara)
├── graphs: [investigation/*, sources/amara-confidential]
├── permissions: [read, write, admin]
│
├── meld:cap/editor-review (Editor)
│   ├── graphs: [investigation/city-hall-contracts]
│   ├── permissions: [read]
│   └── EXCLUDES: sources/amara-confidential
│
├── meld:cap/collaboration (Fellow reporter)
│   ├── graphs: [investigation/city-hall-contracts]
│   ├── permissions: [read, write]
│   └── EXCLUDES: sources/amara-confidential
│
└── meld:cap/legal-review (Newspaper's lawyer)
    ├── graphs: [investigation/city-hall-contracts]
    ├── permissions: [read]
    └── NOTE: May need source identity under subpoena
              (separate encrypted store)
```

**Source protection layers:**
1. **Anonymous in investigation graph**: Source appears as "Source A" with reliability rating
2. **Identity in confidential graph**: Real name, contact info, meeting locations
3. **Nuclear option**: True identity encrypted separately, not in meld at all

## What Makes This Different from Legal Research

| Legal Research | Investigative Journalism |
|----------------|--------------------------|
| Cases are public, citable | Sources often confidential |
| Authority is binary (precedent or not) | Verification is graduated (single source → corroborated → documented) |
| Knowledge accumulates across matters | Each investigation may be isolated (competitive, sensitive) |
| Sharing benefits the firm | Sharing may endanger sources |
| Truth is what courts decided | Truth is what you can prove |

## Frustrations (What Meld Must Solve)

1. **Lost connections**: Name mentioned months ago, forgotten when it resurfaces
2. **Verification chaos**: Which claims have we actually corroborated?
3. **Source protection anxiety**: Notes scattered, hard to sanitize for sharing
4. **Timeline confusion**: Events out of sequence, hard to see patterns
5. **Investigation handoff**: If Amara gets reassigned, months of knowledge trapped in her head
6. **Document overload**: Hundreds of pages, key facts buried

## What Meld Being "Just One Step" Means

Amara investigates. She interviews sources, reviews documents, connects dots, writes stories. She doesn't manage databases.

Her agent is her investigative partner. She talks through what she's learning, and the agent remembers. When she asks "do we know anything about this company?", the answer draws on six months of accumulated investigation—sources, documents, connections, verification status.

**Amara never knows meld exists.** She just has a partner who never forgets, sees connections she might miss, and keeps her sources safe. The knowledge graph emerges from her work; she doesn't have to build it.

That's investigative journalism with perfect memory—and appropriate compartmentalization.
