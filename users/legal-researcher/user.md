# Legal Researcher: Lawyer Building Case Authority

## Identity

**Name**: The Litigator
**Type**: Legal professional with research agent
**Graph**: `meld:graph/firm/{firm-name}`, `meld:graph/matter/{matter-id}`

## Interaction Model

```
┌──────────────┐      natural       ┌──────────────┐      meld CLI      ┌──────────────┐
│   Lawyer     │ ◄─── language ───► │   Agent      │ ◄───────────────► │  Meld Graph  │
│   (Elena)    │                    │  (Claude)    │                    │              │
│              │                    │              │                    │  cases,      │
│  asks about  │                    │  researches, │                    │  statutes,   │
│  cases,      │                    │  tracks,     │                    │  doctrines,  │
│  doctrines,  │                    │  synthesizes │                    │  matters,    │
│  arguments   │                    │              │                    │  arguments   │
└──────────────┘                    └──────────────┘                    └──────────────┘

The lawyer asks questions and discusses cases. The agent builds a
knowledge graph of legal authority that persists across matters.
```

## Who They Are

Elena is a commercial litigator at a mid-size firm. She handles contract disputes, corporate litigation, and occasionally regulatory matters. Her practice involves deep legal research—finding cases that support her arguments, distinguishing unfavorable precedents, and building chains of authority.

She has an AI agent she works with throughout the day. She dictates research questions, discusses case analysis, and talks through arguments. **She never interacts with meld directly**—she just has conversations with her agent about legal questions.

**The problem today**: Every new matter starts from scratch. Elena researched promissory estoppel thoroughly for a case last year. Now a new matter involves the same doctrine, but her agent doesn't remember. She redoes the research, finds the same cases, rebuilds the same analysis.

**The solution**: Meld gives her agent persistent legal memory. Research accumulates. When a doctrine comes up again, her agent already knows the key cases, the distinctions, the arguments that worked.

## Daily Reality

### Morning: New Matter Intake

Elena gets a new file. Client claims breach of confidentiality agreement by a former employee who joined a competitor. She needs to research:
- Enforceability of non-compete clauses in this jurisdiction
- Trade secret protection standards
- Inevitable disclosure doctrine

She asks her agent: *"What do we know about inevitable disclosure in California?"*

If she's researched this before (for any client), her agent remembers. If not, it starts fresh—but anything learned will persist for future matters.

### Midday: Deep Research

Elena is building authority for a motion. She needs cases showing that oral modifications to written contracts are enforceable under certain circumstances. She talks through the research with her agent:

> "Find me cases where courts enforced oral modifications to written contracts despite a no-oral-modification clause. Focus on California appellate decisions. I'm particularly interested in cases involving partial performance or detrimental reliance."

Her agent searches, finds cases, and records them in the graph—linked to the doctrine, the jurisdiction, the matter. The next time she or any colleague needs this research, it's there.

### Afternoon: Argument Development

Elena is drafting a brief. She has a list of cases and needs to structure an argument. She discusses with her agent:

> "Help me structure this. I want to argue that the NDA is enforceable despite ambiguity because the parties' course of performance clarifies intent. What cases support that?"

Her agent queries the graph for cases linked to both "course of performance" and "contract ambiguity," surfaces the strongest authorities, and helps structure the argument. The argument itself gets recorded—linked to the cases that support it.

### Evening: Matter Handoff

Elena is going on leave. A colleague will cover her matters. Instead of a frantic knowledge transfer, her agent has been recording everything: the research paths, the key cases, the arguments developed, the distinctions identified. Her colleague's agent can query the matter graph and pick up where she left off.

## Legal Knowledge Architecture

```
meld:graph/firm/smith-jones
├── meld:doctrine/promissory-estoppel
│   ├── [rdfs:label] "Promissory Estoppel"
│   ├── [meld:jurisdiction] "California"
│   ├── [meld:elements] "promise, reliance, detriment, injustice"
│   └── [skos:related] meld:case/aceves-v-us-bank
│
├── meld:case/aceves-v-us-bank
│   ├── [rdfs:label] "Aceves v. U.S. Bank (2011) 192 Cal.App.4th 218"
│   ├── [meld:citation] "192 Cal.App.4th 218"
│   ├── [meld:court] "California Court of Appeal"
│   ├── [meld:holding] "Promise must be clear and unambiguous"
│   ├── [meld:citedBy] meld:case/granadino-v-wells-fargo
│   └── [meld:appliesTo] meld:doctrine/promissory-estoppel
│
├── meld:case/granadino-v-wells-fargo
│   ├── [meld:cites] meld:case/aceves-v-us-bank
│   ├── [meld:distinguishes] meld:case/laks-v-coast-federal
│   └── [meld:holding] "Detrimental reliance requires more than..."
│
└── meld:graph/matter/2024-0892
    ├── meld:argument/nda-enforceability
    │   ├── [rdfs:label] "NDA enforceable despite ambiguity"
    │   ├── [meld:supportedBy] meld:case/aceves-v-us-bank
    │   ├── [meld:supportedBy] meld:case/xyz...
    │   └── [prov:wasAttributedTo] meld:agent/claude-elena
    │
    └── meld:research/oral-modifications
        ├── [rdfs:label] "Oral modifications research - Jan 2026"
        ├── [meld:query] "oral modification enforceability despite written clause"
        └── [skos:related] meld:case/...
```

## Goals

### Primary Goal: Research That Accumulates

Elena wants legal research to build over time. The cases she finds, the doctrines she analyzes, the distinctions she identifies—all of this should persist. When the same issue arises in a future matter, her agent should already know the landscape.

**Success looks like:**

**What Elena says:**
> "I need to research inevitable disclosure doctrine for a new trade secrets case."

**What happens (if she's researched this before):**
> "I found your previous research on inevitable disclosure from the Acme v. TechCorp matter in 2024. Key California cases: Whyte v. Schlage Lock (2002) 101 Cal.App.4th 1443—California rejects the doctrine. But see Bayer Corp. v. Roche Molecular (1999)—federal court applying California law took a narrower view. Want me to update this research or start fresh?"

---

### Secondary Goal: Authority Chains

Legal arguments rest on chains of authority: this case cites that case, which interprets this statute, which codifies this doctrine. Elena wants her agent to understand and traverse these relationships.

**Success looks like:**

**What Elena says:**
> "What's the strongest California authority for enforcing non-competes against departing employees?"

**What the agent does (invisible):**
```bash
meld query sparql "SELECT ?case ?holding ?citedByCount WHERE {
  ?case meld:jurisdiction 'California' .
  ?case meld:appliesTo <meld:doctrine/non-compete-enforceability> .
  ?case meld:holding ?holding .
  OPTIONAL {
    SELECT ?case (COUNT(?citing) as ?citedByCount) WHERE {
      ?citing meld:cites ?case
    } GROUP BY ?case
  }
} ORDER BY DESC(?citedByCount)"
```

**What Elena sees:**
> "The leading authority is Edwards v. Arthur Andersen LLP (2008) 44 Cal.4th 937—Supreme Court holding that non-compete clauses are void under Business & Professions Code § 16600 with narrow exceptions. It's been cited by 47 cases in our research base. The three exceptions are: sale of business, dissolution of partnership, and... Want me to trace the exception cases?"

---

### Tertiary Goal: Matter Isolation with Firm Learning

Research done for one client shouldn't leak to another client's matter. But the general legal knowledge—doctrine analysis, case summaries, argument structures—should benefit the whole firm.

**Success looks like:**

```
meld:graph/firm/smith-jones          ← General legal knowledge (doctrines, cases)
                                        All firm lawyers' agents can read

meld:graph/matter/2024-0892          ← Client-specific work product
                                        Only matter team agents can access
                                        Contains: arguments, strategy, facts
```

**What Elena says:**
> "This research on inevitable disclosure—is this general doctrine stuff or does it include client-specific strategy?"

**What the agent responds:**
> "The doctrine analysis and case summaries are in the firm knowledge base—any colleague's agent can access them. The specific arguments we developed for how TechCorp's situation differs from the Whyte facts are in the matter graph—only the matter team can see those."

## Interaction Patterns (Lawyer → Agent → Meld)

### Starting Research on a Legal Issue

**What Elena says:**
> "I need to research whether a non-disclosure agreement can be enforced against a third party who wasn't a signatory but knew about the agreement."

**What Elena's agent does (invisible):**
```bash
# Check for existing research
meld query sparql "SELECT ?research ?case WHERE {
  ?research skos:related <meld:doctrine/nda-third-party> .
  OPTIONAL { ?research skos:related ?case . ?case a meld:Case }
}"

# If none found, start fresh session
meld session start --agent "claude-elena" \
  --purpose "Research: NDA enforcement against non-signatory third parties"
```

**What Elena sees (if no prior research):**
> "I don't have prior research on third-party NDA enforcement. Let me search for relevant California authority...
>
> I found several relevant cases. The leading case appears to be Silvaco Data Systems v. Intel Corp. (2010) 184 Cal.App.4th 210, which held that a third party can be liable for inducing breach of an NDA. Should I dive deeper into this line of cases?"

**What Elena sees (if prior research exists):**
> "Good news—we researched this for the Apex matter in 2023. Key finding: third parties can be liable under California's Uniform Trade Secrets Act if they knew or should have known the information was confidential. Lead case: Silvaco Data Systems v. Intel. The Apex brief has a good summary of the elements. Want me to pull that up or update the research?"

---

### Recording a Key Case

**What Elena says:**
> "This case is important—Aceves v. U.S. Bank. It's a 2011 California Court of Appeal decision at 192 Cal.App.4th 218. The holding is that promissory estoppel requires a clear and unambiguous promise. Make sure we remember this one."

**What the agent does (invisible):**
```bash
meld node create --type case \
  --property "label=Aceves v. U.S. Bank (2011) 192 Cal.App.4th 218" \
  --property "citation=192 Cal.App.4th 218" \
  --property "court=California Court of Appeal" \
  --property "year=2011" \
  --property "holding=Promissory estoppel requires a clear and unambiguous promise" \
  --link "meld:appliesTo:meld:doctrine/promissory-estoppel" \
  --link "meld:jurisdiction:California" \
  --link "prov:wasAttributedTo:meld:agent/claude-elena"
```

**What Elena sees:**
> "Got it. I've recorded Aceves v. U.S. Bank and linked it to promissory estoppel doctrine. I also see it's been cited by Granadino v. Wells Fargo in our research base—that case distinguished Aceves on the detrimental reliance element. Want me to add the citation relationship?"

---

### Building an Argument

**What Elena says:**
> "I'm drafting the NDA enforceability section of my brief. My argument is that the NDA should be enforced despite the ambiguous confidentiality definition because the parties' course of performance clarifies what they intended to protect. What cases support this?"

**What the agent does (invisible):**
```bash
# Query for cases supporting both concepts
meld query sparql "SELECT ?case ?holding WHERE {
  ?case meld:appliesTo <meld:doctrine/course-of-performance> .
  ?case meld:appliesTo <meld:doctrine/contract-ambiguity> .
  ?case meld:holding ?holding
}"

# Also check the current matter for prior arguments
meld query backlinks --node "meld:doctrine/course-of-performance"
```

**What Elena sees:**
> "I found three cases that support using course of performance to resolve contract ambiguity:
>
> 1. **Employers Reinsurance Co. v. Superior Court (2008)** - 'When contract language is ambiguous, the parties' conduct is admissible to interpret their intent'
>
> 2. **Wagner v. Columbia Pictures (2007)** - Course of dealing over 10 years established what 'net profits' meant despite ambiguous definition
>
> 3. **City of Hope v. Genentech (2008)** - Parties' consistent treatment of royalty provisions clarified ambiguous licensing terms
>
> For your NDA context, the strongest parallel is probably City of Hope—both involve IP-related agreements where the parties' treatment of confidential information clarified the scope. Want me to draft the argument structure?"

**After Elena approves the argument:**
```bash
# Record the argument with supporting authority
meld node create --type argument \
  --property "label=NDA enforceable via course of performance" \
  --property "content=Despite ambiguous confidentiality definition, parties' course of performance clarifies intent..." \
  --link "meld:supportedBy:meld:case/city-of-hope-v-genentech" \
  --link "meld:supportedBy:meld:case/employers-reinsurance" \
  --link "skos:related:meld:matter/2024-0892" \
  --link "prov:wasAttributedTo:meld:agent/claude-elena"
```

---

### Finding Distinguishing Cases

**What Elena says:**
> "Opposing counsel is going to cite Riverisland Cold Storage v. Fresno-Madera. How do I distinguish it?"

**What the agent does (invisible):**
```bash
# Look up the case
meld node get "meld:case/riverisland-v-fresno-madera" --include-backlinks

# Find cases that distinguish it
meld query sparql "SELECT ?case ?distinction WHERE {
  ?case meld:distinguishes <meld:case/riverisland-v-fresno-madera> .
  ?case meld:distinction ?distinction
}"
```

**What Elena sees:**
> "Riverisland is the 2013 California Supreme Court case that abolished the parol evidence rule's fraud exception—now parol evidence of promissory fraud is admissible. Here's how it's been distinguished:
>
> 1. **Julius Castle Restaurant v. Payne (2013)** - Distinguished where the alleged fraud went to the existence of the contract itself, not just its terms
>
> 2. **Thrifty Payless v. Americana (2015)** - Distinguished in commercial contexts where sophisticated parties negotiated at arm's length
>
> For your case, the Thrifty Payless distinction looks promising—you're dealing with two sophisticated commercial entities. The argument would be that Riverisland's policy concern about protecting unsophisticated parties from fraud doesn't apply here."

---

### Handing Off a Matter

**What Elena says:**
> "I'm going on parental leave next week. David is covering the TechCorp matter. Can you summarize what he needs to know?"

**What the agent does (invisible):**
```bash
# Get all matter-related knowledge
meld query context --focus "meld:matter/2024-0892-techcorp" \
  --max-tokens 8000 \
  --include argument,research,case,fact

# Get research history
meld session list --context "meld:matter/2024-0892-techcorp" --since 90d
```

**What Elena sees:**
> "Here's the TechCorp matter summary for David:
>
> **Key issues:**
> 1. Trade secret misappropriation claim against former CTO
> 2. NDA enforceability (ambiguous confidentiality definition)
> 3. Inevitable disclosure doctrine (weak in California)
>
> **Research completed:**
> - Inevitable disclosure: 12 cases analyzed, conclusion is California disfavors the doctrine (Whyte v. Schlage Lock controls)
> - NDA ambiguity: Course of performance argument developed with 3 supporting cases
> - Trade secret identification: Research on specificity requirements under CUTSA
>
> **Arguments drafted:**
> - NDA enforceability brief section (ready for filing)
> - Trade secret identification memo (needs review)
>
> **Key cases:**
> - Favorable: Silvaco, City of Hope, Employers Reinsurance
> - Unfavorable: Whyte v. Schlage (must distinguish)
>
> **Pending:**
> - Reply brief due Feb 15
> - Need to research inevitable disclosure in federal courts applying California law
>
> David's agent will have full access to all of this. Want me to draft a handoff memo for him?"

## Capability Model for Law Firms

```
Capability Hierarchy:

meld:cap/firm-admin (Managing Partner)
├── graphs: [firm/*, matter/*]
├── permissions: [read, write, admin]
│
├── meld:cap/attorney-full (Partners, Associates)
│   ├── graphs: [firm/smith-jones, matter/{assigned-matters}]
│   ├── permissions: [read, write]
│   │
│   └── meld:cap/matter-team (Per-matter access)
│       ├── graphs: [firm/smith-jones, matter/2024-0892]
│       └── permissions: [read, write]
│
├── meld:cap/paralegal (Support staff)
│   ├── graphs: [firm/smith-jones, matter/{assigned-matters}]
│   └── permissions: [read]
│
└── meld:cap/client-portal (Client access)
    ├── graphs: [matter/2024-0892/client-visible]
    └── permissions: [read]
```

**Ethical walls**: When Elena is conflicted out of a matter, her capability is revoked for that matter's graph. Her agent literally cannot access that knowledge.

## Frustrations (What Meld Must Solve)

1. **Research amnesia**: Same doctrines researched repeatedly across matters
2. **Knowledge silos**: Senior partner's research never benefits junior associates
3. **Handoff chaos**: Matter transitions lose months of institutional knowledge
4. **Citation sprawl**: Cases saved in documents, not queryable or connected
5. **No authority chains**: Can't easily trace "what cases cite this case"
6. **Conflict exposure**: No clean way to wall off conflicted matters

## What Meld Being "Just One Step" Means

Elena practices law. She interviews clients, drafts briefs, argues motions, negotiates settlements. Legal research is a necessary but tedious part of that work.

Her agent handles research. She asks questions in natural language. The agent finds cases, builds authority chains, remembers what was learned. Meld is the invisible substrate that makes her agent's memory persistent and connected.

**Elena never knows meld exists.** She just has conversations with her agent about legal questions, and somehow it remembers things—across matters, across years. The cases she found last year for one client help her automatically when the same doctrine arises for a new client.

That's the point: accumulated expertise, without the overhead of organizing it.
