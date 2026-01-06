# Cross-Functional Team: Product / Dev / UX Collaborative

## Identity

**Name**: The Product Squad
**Type**: Distributed team with specialized agents
**Graph**: `meld:graph/project/{product-name}`

## Interaction Model

```
┌──────────────┐      natural       ┌──────────────┐      meld CLI      ┌──────────────┐
│    Human     │ ◄─── language ───► │   Agent      │ ◄───────────────► │  Meld Graph  │
│  (Sarah/     │                    │  (Claude)    │                    │  (shared)    │
│   Marcus/    │                    │              │                    │              │
│   Priya)     │                    │  queries,    │                    │  persistent  │
│              │                    │  records,    │                    │  linked      │
│  speaks      │                    │  synthesizes │                    │  knowledge   │
│  naturally   │                    │              │                    │              │
└──────────────┘                    └──────────────┘                    └──────────────┘

The human never runs meld commands. They converse with their agent.
The agent uses meld as its memory substrate—invisible to the human.
```

## Who They Are

A cross-functional product team: a product manager making roadmap decisions, developers implementing features, and UX researchers/designers shaping the experience. Each discipline has its own tools, terminology, and concerns—but they're building the same thing.

Each team member has an AI agent they work with daily. The PM talks to her agent about customer feedback and roadmap decisions. Developers talk to their agents about implementation. UX researchers talk to their agents about user insights. **The human never touches meld directly**—they just talk to their agent, and the agent handles memory.

**The problem today**: Each agent operates in isolation. Sarah's agent knows what Sarah told it. Marcus's agent knows what Marcus told it. Priya's agent knows what Priya told it. No shared memory connects "users struggle with X" to "we decided Y because Z" to "implemented via W."

**The solution**: Meld gives all agents access to a shared knowledge graph. When Sarah tells her agent about customer feedback, it persists. When Marcus's agent starts implementing, it queries and finds Sarah's feedback and Priya's research—without Marcus having to know they exist.

## Daily Reality

### The PM: Sarah

Sarah spends her mornings in customer calls, afternoons in stakeholder meetings, evenings writing specs. Her agent helps synthesize feedback:

> "Analyze these 12 support tickets and identify patterns"

The agent finds patterns, Sarah makes decisions, but the *reasoning* evaporates. Two sprints later, a developer asks "why did we prioritize feature X?" and Sarah has to reconstruct the logic from memory and scattered Slack threads.

**What Sarah wants from meld**: Decision provenance. When she decides to prioritize a feature, the supporting evidence (user quotes, metric trends, competitive analysis) should link to that decision. When someone asks "why?", the graph has the answer.

### The Developer: Marcus

Marcus implements what the specs describe, but specs are incomplete. He makes dozens of micro-decisions daily: error handling strategies, API shapes, performance tradeoffs. His agent helps with implementation but doesn't know *why* the feature exists or *who* it's for.

> "How should I handle the edge case where a user has no payment method?"

The agent suggests technical solutions, but the *right* answer depends on UX research Marcus hasn't seen. Is this a common case? Do users find it confusing? The agent doesn't know.

**What Marcus wants from meld**: Context from other disciplines. When implementing a feature, he wants his agent to surface relevant UX findings and product decisions—not because he asked, but because they're linked to what he's building.

### The UX Researcher: Priya

Priya conducts user interviews, synthesizes insights, and translates findings into design recommendations. Her agent helps analyze transcripts:

> "What themes emerge from these 8 user interviews about onboarding?"

The agent finds themes, Priya writes a research report, but the report sits in a Google Doc. Developers don't read it. Product skims it. The insights don't connect to implementation decisions.

**What Priya wants from meld**: Research that influences. When a developer's agent makes a decision about onboarding flow, it should know what users actually said. When product asks "do users want feature X?", the answer should come from linked research, not memory.

## Team Knowledge Architecture

```
meld:graph/project/acme-app
├── meld:entity/feature/onboarding-v2
│   ├── [dcterms:created] "2026-01-03"
│   ├── [meld:decidedBy] meld:agent/sarah-pm
│   ├── [prov:wasInfluencedBy] meld:research/user-interviews-dec
│   └── [skos:related] meld:entity/component/signup-flow
│
├── meld:research/user-interviews-dec
│   ├── [rdfs:label] "December user interviews - onboarding"
│   ├── [prov:wasAttributedTo] meld:agent/priya-ux
│   ├── [meld:finding] "7/8 users confused by email verification step"
│   └── [meld:confidence] 0.9
│
├── meld:decision/remove-email-verification
│   ├── [rdfs:label] "Remove email verification from signup"
│   ├── [prov:wasInfluencedBy] meld:research/user-interviews-dec
│   ├── [meld:decidedBy] meld:agent/sarah-pm
│   ├── [meld:tradeoff] "Lower friction vs. potential spam accounts"
│   └── [meld:implementedIn] meld:entity/component/signup-flow
│
└── meld:entity/component/signup-flow
    ├── [prov:wasAttributedTo] meld:agent/marcus-dev
    ├── [meld:implements] meld:decision/remove-email-verification
    └── [meld:technicalNote] "Rate limiting added to mitigate spam risk"
```

## Goals

### Primary Goal: Connected Knowledge Across Disciplines

The team wants a shared memory that crosses discipline boundaries. When Marcus's agent works on signup flow, it should automatically surface Priya's research findings and Sarah's product decisions—without Marcus having to know they exist.

**Success looks like**: Developer's agent queries what it's implementing and receives:
- Product context: "This feature was prioritized because..."
- UX context: "Users said X about this flow..."
- Technical context: "Previous implementation had Y issue..."

```bash
# Marcus's agent queries context for what it's building
meld query context --focus "meld:entity/component/signup-flow" \
  --max-tokens 4000 \
  --include fact,decision,research

# Returns findings from Priya, decisions from Sarah, prior tech notes
```

### Secondary Goal: Decision Traceability

When someone asks "why is it like this?", the answer should be in the graph. Not in someone's memory, not in a Slack thread from 6 months ago, but in linked nodes with provenance.

**Success looks like**: Any team member can trace a feature back to the research that motivated it, the decision that approved it, and the tradeoffs that shaped it.

```bash
# "Why does onboarding skip email verification?"
meld query path --from "meld:entity/component/signup-flow" \
  --to "meld:research/user-interviews-dec" \
  --max-hops 3

# Returns: signup-flow → implements → decision/remove-email-verification
#          → wasInfluencedBy → research/user-interviews-dec
```

### Tertiary Goal: Institutional Memory That Survives Turnover

Teams change. People leave, new people join. The knowledge in people's heads walks out the door. The team wants accumulated knowledge to persist in the graph, accessible to new team members and their agents.

**Success looks like**: New team member's agent can query project history and understand not just *what* was built, but *why*.

```bash
# New team member: "What decisions shaped the current auth flow?"
meld query sparql --cap "meld:cap/team-read" \
  "SELECT ?decision ?rationale WHERE {
    ?decision meld:implements <meld:entity/feature/auth> .
    ?decision meld:tradeoff ?rationale
  }"
```

## Interaction Patterns (Human → Agent → Meld)

### PM Recording Decisions

**What Sarah says:**
> "We're going to prioritize onboarding over the dashboard redesign. The user interviews showed 40% drop-off at signup—that's the bigger problem right now."

**What Sarah's agent does (invisible to Sarah):**
```bash
meld node create --type decision \
  --property "content=Prioritize onboarding improvements over dashboard redesign" \
  --property "rationale=User interviews show 40% drop-off at signup" \
  --link "prov:wasInfluencedBy:meld:research/user-interviews-dec" \
  --link "meld:decidedBy:meld:agent/sarah-pm"
```

**What Sarah sees:**
> "Got it. I've noted that decision and linked it to Priya's December research. When Marcus picks up onboarding work, his agent will see why it was prioritized."

---

### UX Recording Research Findings

**What Priya says:**
> "Just finished the December interview analysis. Key findings: 7 out of 8 users were confused by the email verification step, and 5 expected a social login option. These were 45-minute semi-structured interviews."

**What Priya's agent does (invisible to Priya):**
```bash
meld node create --type research \
  --property "content=December user interviews - onboarding friction" \
  --property "finding=7/8 users confused by email verification step" \
  --property "finding=5/8 users expected social login option" \
  --property "methodology=Semi-structured interviews, 45min each" \
  --link "meld:confidence:0.9" \
  --link "prov:wasAttributedTo:meld:agent/priya-ux"
```

**What Priya sees:**
> "I've recorded those findings. They're now linked to the onboarding feature area. Sarah's agent will surface them when she's making prioritization decisions."

---

### Developer Getting Context Before Implementation

**What Marcus says:**
> "I'm starting on the onboarding signup flow. What should I know?"

**What Marcus's agent does (invisible to Marcus):**
```bash
meld session start --agent "claude-code-marcus" \
  --purpose "Implement onboarding v2 signup flow" \
  --context "meld:entity/feature/onboarding-v2"

meld query context --focus "meld:entity/feature/onboarding-v2" --max-tokens 4000
```

**What Marcus sees:**
> "Here's what I found about onboarding:
>
> **Why it's prioritized:** Sarah decided to prioritize this over dashboard work because of the 40% signup drop-off.
>
> **User research:** Priya's December interviews found that 7/8 users were confused by email verification, and 5/8 expected social login.
>
> **Implication:** You might want to consider simplifying or removing email verification. Want me to check if there are any security constraints on that?"

---

### Team Lead Reviewing Progress

**What the team lead says:**
> "What did the team learn this sprint?"

**What the agent does:**
```bash
meld query nodes --since 7d --type decision,research,fact
```

**What the team lead sees:**
> "This sprint the team added:
>
> **3 decisions:**
> - Prioritize onboarding over dashboard (Sarah)
> - Remove email verification from signup (Sarah)
> - Use rate limiting instead of email verification for spam (Marcus)
>
> **1 research study:**
> - December onboarding interviews - 8 participants (Priya)
>
> **5 technical facts:**
> - Rate limiter configured at 10 signups/IP/hour
> - Social login OAuth integration complete
> - ..."

## Capability Model for Teams

```
Team Capability Hierarchy:

meld:cap/project-admin (Sarah - PM)
├── graphs: [project/acme-app, public]
├── permissions: [read, write, admin]
│
├── meld:cap/team-write (All team members)
│   ├── graphs: [project/acme-app, public]
│   ├── permissions: [read, write]
│   │
│   ├── meld:cap/team-read (Stakeholders, new members)
│   │   ├── graphs: [project/acme-app, public]
│   │   └── permissions: [read]
│   │
│   └── meld:cap/contractor-read (External contractors)
│       ├── graphs: [project/acme-app/public-subset, public]
│       ├── permissions: [read]
│       └── expires: "2026-02-01"
```

```bash
# PM creates team capability
meld cap create --graphs "meld:graph/project/acme-app,meld:graph/public" \
  --permissions read,write

# Attenuate for stakeholder (read-only)
meld cap attenuate --cap "meld:cap/team-abc" \
  --permissions read
```

## Frustrations (What Meld Must Solve)

1. **Discipline silos**: PM decisions don't reach dev agents, UX research doesn't reach anyone
2. **Lost rationale**: "Why did we build it this way?" answered by shrugs
3. **Context switching cost**: Explaining project history to every new agent session
4. **Documentation decay**: Written docs outdated within weeks, graph stays current
5. **Knowledge hoarding**: Insights trapped in individuals, not shared with team
6. **Agent isolation**: Each team member's agent knows only their slice

## What Meld Being "Just One Step" Means

For the cross-functional team, meld is invisible infrastructure. The humans never see it, never think about it, never run commands. They talk to their agents. Their agents talk to meld.

**Sarah's experience**: She talks to her agent about customer feedback and product decisions. She doesn't know her agent is creating nodes and links in a graph. She just knows that somehow, Marcus's agent already knows the context when he starts implementing.

**Marcus's experience**: He asks his agent for context before coding. He doesn't know his agent is running SPARQL queries. He just gets a synthesis of research findings and product decisions that helps him make better implementation choices.

**Priya's experience**: She tells her agent about research findings. She doesn't know her agent is recording them as linked data. She just sees, weeks later, that her research actually influenced product decisions—and her agent can tell her exactly how.

**The team's experience**: Knowledge flows without meetings. Research reaches developers. Decisions reach implementers. Context survives turnover. And nobody had to write documentation—it accumulated through normal work.

## Anti-Pattern: Meld as Documentation System

Meld is not where you write docs. It's where knowledge accumulates through work. The distinction matters:

| Documentation (not meld) | Knowledge Graph (meld) |
|--------------------------|------------------------|
| Written after the fact | Created during work |
| Single author | Multiple contributors |
| Prose format | Structured nodes + links |
| Static snapshot | Living, queryable |
| Read by humans | Read by agents + humans |

The graph emerges from agents recording what they learn. Docs are a *view* on the graph, not the source of truth.
