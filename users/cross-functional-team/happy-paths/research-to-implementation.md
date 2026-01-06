# Happy Path: Research Finding → Product Decision → Implementation

## Scenario

A UX researcher discovers a usability issue through user interviews. This finding influences a product decision, which a developer then implements. Each step is recorded by different agents, creating a traceable chain.

## Preconditions

- Team has shared project graph `meld:graph/project/acme-app`
- Each team member has write capability to project graph
- Feature entity `meld:entity/feature/checkout` exists

## Flow

### Phase 1: UX Research (Priya's Agent)

```bash
# Priya's agent records research findings
meld session start --agent "claude-ux-priya" \
  --purpose "Analyze checkout usability interviews" \
  --context "meld:entity/feature/checkout"

# Create research node with findings
meld node create --type research \
  --property "label=January checkout usability study" \
  --property "methodology=8 moderated usability sessions, 30min each" \
  --property "finding=6/8 users abandoned cart when shipping cost appeared late" \
  --property "finding=5/8 users expected to see total before entering payment" \
  --property "recommendation=Show shipping estimate earlier in flow" \
  --link "skos:related:meld:entity/feature/checkout" \
  --link "meld:confidence:0.85" \
  --link "prov:wasAttributedTo:meld:agent/claude-ux-priya"

# Response:
{
  "ok": true,
  "data": {
    "id": "meld:research/checkout-usability-jan",
    "type": "research",
    "created_at": "2026-01-10T14:30:00Z",
    "links_created": 3
  }
}

meld session end --summary "Identified shipping cost visibility as key checkout friction point"
```

### Phase 2: Product Decision (Sarah's Agent)

```bash
# Sarah's agent reviews research and records decision
meld session start --agent "claude-pm-sarah" \
  --purpose "Sprint planning - checkout improvements"

# Query recent research
meld query nodes --type research --since 14d \
  --has-link "skos:related:meld:entity/feature/checkout"

# Response shows Priya's research
# Sarah's agent reads findings, Sarah makes decision

# Record the decision with linked rationale
meld node create --type decision \
  --property "label=Show shipping estimate on cart page" \
  --property "rationale=Research shows 75% cart abandonment linked to late shipping cost reveal" \
  --property "tradeoff=Requires shipping API call earlier, slight latency increase" \
  --property "priority=P1 for Q1" \
  --link "prov:wasInfluencedBy:meld:research/checkout-usability-jan" \
  --link "meld:decidedBy:meld:agent/claude-pm-sarah" \
  --link "meld:implements:meld:entity/feature/checkout"

# Response:
{
  "ok": true,
  "data": {
    "id": "meld:decision/early-shipping-estimate",
    "type": "decision",
    "created_at": "2026-01-12T10:00:00Z",
    "links_created": 3
  }
}

meld session end --summary "Prioritized early shipping estimate based on usability research"
```

### Phase 3: Implementation (Marcus's Agent)

```bash
# Marcus's agent starts implementation with full context
meld session start --agent "claude-code-marcus" \
  --purpose "Implement early shipping estimate on cart" \
  --context "meld:entity/feature/checkout"

# Query for context - gets research AND decision automatically
meld query context --focus "meld:entity/feature/checkout" --max-tokens 4000

# Response includes:
{
  "ok": true,
  "data": {
    "focus": "meld:entity/feature/checkout",
    "nodes": [
      {
        "id": "meld:research/checkout-usability-jan",
        "type": "research",
        "properties": {
          "finding": "6/8 users abandoned cart when shipping cost appeared late"
        },
        "confidence": 0.85
      },
      {
        "id": "meld:decision/early-shipping-estimate",
        "type": "decision",
        "properties": {
          "label": "Show shipping estimate on cart page",
          "tradeoff": "Requires shipping API call earlier, slight latency increase"
        }
      }
    ]
  }
}

# Marcus's agent now knows WHY this feature exists and WHAT tradeoffs were accepted
# Implementation proceeds with full context...

# Record technical decision made during implementation
meld node create --type fact \
  --property "content=Using cached shipping rates with 15min TTL to reduce API latency" \
  --property "technical_context=ShippingService.getEstimate() now returns cached result" \
  --link "skos:related:meld:decision/early-shipping-estimate" \
  --link "meld:confidence:0.95" \
  --link "prov:wasAttributedTo:meld:agent/claude-code-marcus"

# Link implementation to decision
meld link create --source "meld:entity/component/cart-shipping-display" \
  --predicate "meld:implements" \
  --target "meld:decision/early-shipping-estimate"

meld session end --summary "Implemented shipping estimate on cart with 15min cache for performance"
```

### Phase 4: Future Query (Anyone)

```bash
# 3 months later: new developer asks "why do we show shipping on cart page?"

meld query path --from "meld:entity/component/cart-shipping-display" \
  --to "meld:research/checkout-usability-jan" \
  --max-hops 4

# Response:
{
  "ok": true,
  "data": {
    "paths": [
      [
        {"node": "meld:entity/component/cart-shipping-display", "label": "Cart shipping display"},
        {"link": "meld:implements", "direction": "forward"},
        {"node": "meld:decision/early-shipping-estimate", "label": "Show shipping estimate on cart page"},
        {"link": "prov:wasInfluencedBy", "direction": "forward"},
        {"node": "meld:research/checkout-usability-jan", "label": "January checkout usability study"}
      ]
    ]
  }
}

# The chain is clear:
# Component → implements → Decision → wasInfluencedBy → Research
#
# New developer (or their agent) now understands:
# - What: Shipping estimate shown on cart
# - Why: 75% abandonment when shipping revealed late
# - Evidence: 6/8 users in usability study
# - Tradeoff: Accepted latency for cached API calls
```

## Postconditions

- Research linked to feature it informs
- Decision linked to research that motivated it
- Implementation linked to decision it fulfills
- Technical choices documented with rationale
- Full traceability from code to user insight

## Knowledge Graph After Flow

```
meld:research/checkout-usability-jan
  ├── [finding] "6/8 users abandoned when shipping appeared late"
  ├── [prov:wasAttributedTo] meld:agent/claude-ux-priya
  └── [skos:related] meld:entity/feature/checkout
        │
        ▼ (discovered via backlinks)
meld:decision/early-shipping-estimate
  ├── [prov:wasInfluencedBy] meld:research/checkout-usability-jan
  ├── [meld:decidedBy] meld:agent/claude-pm-sarah
  ├── [tradeoff] "Requires shipping API call earlier"
  └── [meld:implements] meld:entity/feature/checkout
        │
        ▼ (discovered via backlinks)
meld:entity/component/cart-shipping-display
  ├── [meld:implements] meld:decision/early-shipping-estimate
  └── [prov:wasAttributedTo] meld:agent/claude-code-marcus
        │
        ▼ (related fact)
meld:fact/shipping-cache-decision
  ├── [content] "Using cached shipping rates with 15min TTL"
  └── [skos:related] meld:decision/early-shipping-estimate
```

## What the Team Gained

1. **Priya**: Research findings are linked to outcomes, visible impact
2. **Sarah**: Decisions have documented rationale, defensible to stakeholders
3. **Marcus**: Implementation context without asking, understood tradeoffs
4. **New team members**: Can trace any code to its motivation
5. **Future agents**: Start with accumulated team knowledge
