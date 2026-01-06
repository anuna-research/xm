# Happy Path: Agent-Mediated Team Workflow

## Scenario

Each team member interacts with meld exclusively through their LLM agent. The human never runs meld commands directly—they have natural conversations, and the agent uses meld as its memory substrate.

## The Interaction Model

```
┌─────────────────────────────────────────────────────────────────┐
│                         Human (Sarah)                            │
│                                                                  │
│  "I just got out of customer calls. 3 customers complained      │
│   about the checkout flow. Can you note that and see if         │
│   it connects to anything we already know?"                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ natural language
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Sarah's Agent (Claude)                      │
│                                                                  │
│  1. Query meld for existing checkout-related knowledge          │
│  2. Create fact node with today's feedback                      │
│  3. Link to existing research/decisions                         │
│  4. Summarize connections back to Sarah                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ meld CLI
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Meld Graph                               │
│                                                                  │
│  Persistent, queryable, shared across all team agents           │
└─────────────────────────────────────────────────────────────────┘
```

## Flow: PM Recording Customer Feedback

### What Sarah Says (natural language)

> "I just finished three customer calls. Two enterprise customers and one SMB. All three mentioned the checkout is confusing—specifically that shipping costs surprise them at the end. The enterprise folks said it's causing their finance teams to reject purchases. Can you capture this and see if we've heard this before?"

### What Sarah's Agent Does (invisible to Sarah)

```bash
# 1. Start session for this interaction
meld session start --agent "claude-pm-sarah" \
  --purpose "Customer feedback - checkout friction"

# 2. Query for existing checkout knowledge
meld query sparql "SELECT ?node ?content ?type WHERE {
  ?node skos:related <meld:entity/feature/checkout> .
  ?node rdfs:label ?content .
  ?node rdf:type ?type
} LIMIT 20"

# Response reveals Priya's research from last month:
# - meld:research/checkout-usability-jan
#   "6/8 users abandoned cart when shipping cost appeared late"

# 3. Record today's customer feedback
meld node create --type fact \
  --property "label=Customer feedback: checkout shipping surprise (Jan 15)" \
  --property "content=3/3 customers cited late shipping cost reveal as friction point" \
  --property "source=Customer calls - 2 enterprise, 1 SMB" \
  --property "business_impact=Enterprise finance teams rejecting purchases" \
  --link "skos:related:meld:entity/feature/checkout" \
  --link "skos:related:meld:research/checkout-usability-jan" \
  --link "meld:confidence:0.9" \
  --link "prov:wasAttributedTo:meld:agent/claude-pm-sarah"

# 4. End session
meld session end --summary "Recorded customer feedback corroborating checkout usability research"
```

### What Sarah Sees (agent's response)

> "I've recorded the feedback from your three calls. This is the third signal about shipping cost visibility in checkout:
>
> 1. **Priya's usability research** (Jan 10): 6/8 users abandoned cart when shipping appeared late
> 2. **Support tickets** (Dec): 12 tickets mentioning 'surprise' shipping costs
> 3. **Today's customer calls**: 3/3 enterprise + SMB customers with same friction
>
> The enterprise angle is new—finance team rejections could be a compelling business case for prioritization. Want me to draft a decision document recommending we address this in the next sprint?"

---

## Flow: Developer Getting Context Before Implementation

### What Marcus Says (natural language)

> "I'm picking up the ticket to add shipping estimates to the cart page. What do I need to know before I start?"

### What Marcus's Agent Does (invisible to Marcus)

```bash
# 1. Start session for this work
meld session start --agent "claude-code-marcus" \
  --purpose "Implement shipping estimate on cart" \
  --context "meld:entity/feature/checkout"

# 2. Query for all context around this feature
meld query context --focus "meld:entity/feature/checkout" \
  --max-tokens 6000 \
  --include decision,research,fact

# Response includes:
# - Decision: "Show shipping estimate on cart page" (Sarah, Jan 13)
# - Research: "6/8 users abandoned when shipping appeared late" (Priya, Jan 10)
# - Fact: "3/3 customers cited shipping surprise" (Sarah, Jan 15)
# - Technical: Previous shipping API integration notes

# 3. Query for any technical constraints or prior attempts
meld query sparql "SELECT ?fact ?content WHERE {
  ?fact skos:related <meld:entity/feature/checkout> .
  ?fact rdf:type meld:TechnicalFact .
  ?fact rdfs:label ?content
}"

# 4. Check for related decisions with tradeoffs
meld query sparql "SELECT ?decision ?tradeoff WHERE {
  ?decision meld:implements <meld:entity/feature/checkout> .
  OPTIONAL { ?decision meld:tradeoff ?tradeoff }
}"
```

### What Marcus Sees (agent's response)

> "Here's what I found about the shipping estimate feature:
>
> **Why we're doing this:**
> - Priya's research found 75% of users (6/8) abandoned checkout when shipping costs appeared late
> - Sarah recorded 3 customer calls this week with the same complaint—enterprise customers say their finance teams reject purchases due to unexpected costs
>
> **The decision:**
> Sarah prioritized this P1 on Jan 13. Accepted tradeoff: we'll need to call the shipping API earlier in the flow, which adds latency. She noted this is acceptable given the abandonment data.
>
> **Technical context:**
> - Shipping API is `ShippingService.getEstimate(cart, address)`
> - Current integration is in `checkout/shipping.ts`
> - No prior notes about cart-page integration
>
> **What I'd suggest:**
> Given the latency concern, we could cache shipping estimates by zip code prefix with a short TTL. Want me to start with that approach?"

---

## Flow: UX Researcher Checking Impact of Past Work

### What Priya Says (natural language)

> "Remember that checkout usability study I did earlier this month? Did anything come of it?"

### What Priya's Agent Does (invisible to Priya)

```bash
# 1. Find Priya's research
meld query nodes --type research \
  --has-link "prov:wasAttributedTo:meld:agent/claude-ux-priya" \
  --since 30d

# 2. Find what links TO that research (what was influenced by it)
meld query backlinks --node "meld:research/checkout-usability-jan"

# Response shows:
# - meld:decision/early-shipping-estimate [prov:wasInfluencedBy]
# - meld:fact/customer-feedback-jan15 [skos:related]

# 3. Check implementation status
meld query sparql "SELECT ?component ?status WHERE {
  ?component meld:implements <meld:decision/early-shipping-estimate> .
  OPTIONAL { ?component meld:status ?status }
}"
```

### What Priya Sees (agent's response)

> "Your checkout usability study from January 10th has had real impact:
>
> **Decisions influenced:**
> - Sarah created a P1 decision on Jan 13 to show shipping estimates earlier, directly citing your finding that 6/8 users abandoned due to late shipping reveal
>
> **Corroborating evidence:**
> - Sarah recorded 3 customer calls on Jan 15 with the same feedback
> - 12 support tickets from December mentioned the same issue
>
> **Implementation status:**
> - Marcus started implementing it yesterday
> - It's linked to your research in the decision chain
>
> Your research literally drove a sprint priority. Nice work!"

---

## Flow: New Team Member Onboarding

### What Jordan (new dev) Says (natural language)

> "I'm new to the team. I've been assigned to work on checkout. Can you catch me up on what I need to know?"

### What Jordan's Agent Does (invisible to Jordan)

```bash
# 1. Start session
meld session start --agent "claude-code-jordan" \
  --purpose "Onboarding - checkout feature area"

# 2. Get comprehensive context
meld query context --focus "meld:entity/feature/checkout" \
  --max-tokens 8000

# 3. Get decision history
meld query sparql "SELECT ?decision ?label ?date ?rationale WHERE {
  ?decision meld:implements <meld:entity/feature/checkout> .
  ?decision rdfs:label ?label .
  ?decision dcterms:created ?date .
  OPTIONAL { ?decision meld:rationale ?rationale }
} ORDER BY DESC(?date) LIMIT 10"

# 4. Get research that influenced checkout
meld query sparql "SELECT ?research ?finding WHERE {
  ?decision meld:implements <meld:entity/feature/checkout> .
  ?decision prov:wasInfluencedBy ?research .
  ?research meld:finding ?finding
}"

# 5. Get technical facts
meld query nodes --type fact \
  --has-link "skos:related:meld:entity/feature/checkout"
```

### What Jordan Sees (agent's response)

> "Welcome! Here's what you need to know about checkout:
>
> **Current state:**
> Checkout is a key conversion point. Recent focus has been on reducing abandonment.
>
> **Key research:**
> - Priya ran a usability study (Jan 10) that found 75% of users abandon when shipping costs appear late in the flow
> - This was corroborated by customer calls and support tickets
>
> **Recent decisions:**
> 1. **Early shipping estimate** (P1, Jan 13): Show shipping on cart page before checkout. Marcus is implementing this now.
> 2. **Guest checkout simplification** (P2, Dec): Reduce form fields. Completed last sprint.
>
> **Technical context:**
> - Checkout flow lives in `src/checkout/`
> - Shipping integration: `ShippingService.getEstimate()`
> - Marcus is adding cart-page shipping with caching for performance
>
> **Key contacts:**
> - Sarah (PM) for prioritization questions
> - Priya (UX) for user research
> - Marcus for current shipping implementation
>
> Want me to dive deeper into any of these areas?"

---

## What the Human Never Sees

The human never sees:
- `meld session start`
- `meld query sparql`
- `meld node create`
- JSON responses
- Graph URIs like `meld:entity/feature/checkout`

They see natural conversation. The agent translates between human intent and graph operations.

## What the Agent Provides

The agent:
1. **Interprets intent**: "catch me up" → comprehensive context query
2. **Queries meld**: Finds relevant nodes, follows links, discovers backlinks
3. **Synthesizes**: Turns graph data into narrative
4. **Records**: Creates nodes/links when human shares information
5. **Connects**: Links new information to existing knowledge

## The Human's Mental Model

The human thinks: "My agent remembers what the team knows."

The reality: The agent queries a shared graph that all team agents contribute to.

The human doesn't need to know about:
- Graph structure
- SPARQL queries
- Named graphs
- Capabilities (handled at setup)
- Node types or URIs

They just talk to their agent, and the agent has team memory.
