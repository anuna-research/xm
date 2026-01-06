# Happy Path: Connection Surfaces Months Later

## Scenario

A name mentioned in passing during an early interview becomes significant months later when it appears in documents. Amara's agent catches the connection she would have missed.

## Phase 1: Initial Source Interview (March 2026)

Amara is investigating city hall contracts. A source mentions many names and companies. Most seem like background noise.

**What Amara says:**
> "Just finished a long interview with a former city procurement officer. Lots of general complaints about how contracts get steered. Mentioned a few names—there's apparently a guy named Frank Deluca who used to work in the mayor's office and now 'consults' for contractors. Source called him a 'fixer.' Also mentioned some company called Great Lakes Development that's been getting favorable treatment. Oh, and apparently there's an annual golf tournament where all the deals happen—the 'Lakefront Classic' or something. Probably not important but figured I'd mention it."

**What the agent does (invisible):**
```bash
# Record all entities mentioned, even seemingly minor ones
meld node create --type entity/person \
  --property "label=Frank Deluca" \
  --property "role=Consultant (alleged fixer)" \
  --property "former_position=Mayor's office" \
  --link "meld:source:meld:source/procurement-officer-former" \
  --link "meld:verificationStatus:single-source-background"

meld node create --type entity/org \
  --property "label=Great Lakes Development" \
  --property "allegation=Receives favorable contract treatment" \
  --link "meld:source:meld:source/procurement-officer-former"

meld node create --type entity/event \
  --property "label=Lakefront Classic golf tournament" \
  --property "context=Alleged venue for deal-making" \
  --link "meld:source:meld:source/procurement-officer-former"
```

**What Amara sees:**
> "Got it. I've noted Frank Deluca (alleged fixer, ex-mayor's office), Great Lakes Development, and the Lakefront Classic golf tournament. These are marked as background—single source, unverified. They'll be here if they ever become relevant."

Amara moves on. She's focused on Lakeshore Holdings and the plaza contract. The other names fade from her conscious memory.

---

## Phase 2: Investigation Continues (April-July 2026)

Amara spends months on the Lakeshore Holdings investigation. She doesn't think about Frank Deluca or Great Lakes Development. They were just background noise from one interview.

---

## Phase 3: Document Review Surfaces Connection (August 2026)

Amara obtains a trove of city emails through FOIA. She's reviewing them with her agent.

**What Amara says:**
> "Going through these city emails. There's a thread about the plaza contract procurement. Let me read you the relevant parts... 'Per Frank's recommendation, we should fast-track the Lakeshore bid.' Signed by the procurement director. Who's Frank?"

**What the agent does (invisible):**
```bash
# Search for any entity named "Frank"
meld query sparql "SELECT ?person ?context ?source WHERE {
  ?person a meld:Person .
  ?person rdfs:label ?label .
  FILTER(CONTAINS(LCASE(?label), 'frank'))
  OPTIONAL { ?person meld:role ?context }
  OPTIONAL { ?person meld:source ?source }
}"
```

**What Amara sees:**
> "I found a Frank in your notes—**Frank Deluca**:
>
> **From your March interview** (former procurement officer):
> - Described as a 'fixer' who consults for contractors
> - Former mayor's office employee
> - Source said he facilitates steering of contracts
>
> This email says the plaza contract was fast-tracked 'per Frank's recommendation.' If this is Frank Deluca, you have documentary evidence connecting an alleged fixer to the specific contract you're investigating.
>
> This upgrades the Deluca connection from 'background noise' to 'potentially central.' Want me to search for other mentions of Deluca or 'Frank' in the email trove?"

**What Amara says:**
> "Holy shit, I completely forgot about him. Yes, search everything for Deluca and Frank."

**What the agent does (invisible):**
```bash
# Search emails (external tool), then record findings
# After search completes:

meld node update "meld:entity/person/frank-deluca" \
  --property "verificationStatus=corroborated" \
  --property "evidence_note=Name appears in city emails recommending Lakeshore contract"

meld node create --type evidence \
  --property "label=Procurement director email re: Lakeshore fast-track" \
  --property "document_type=City email (FOIA)" \
  --property "key_quote=Per Frank's recommendation, we should fast-track the Lakeshore bid" \
  --property "date=2025-02-28" \
  --link "skos:related:meld:entity/person/frank-deluca" \
  --link "meld:corroborates:meld:claim/contract-steering"

meld link create --source "meld:entity/person/frank-deluca" \
  --predicate "meld:connectedTo" \
  --target "meld:entity/org/lakeshore-holdings" \
  --property "evidence=City email FOIA"
```

**What Amara sees:**
> "Found 7 more emails mentioning 'Frank' in the context of city contracts:
>
> 1. **Feb 28, 2025**: 'Per Frank's recommendation, fast-track Lakeshore bid' (procurement director)
> 2. **Mar 3, 2025**: 'Frank will handle the paperwork' (mayor's office)
> 3. **Mar 10, 2025**: 'Confirmed with Frank—Lakeshore is good to go'
> 4. **Apr 15, 2025**: 'Frank says Great Lakes is next in line for the waterfront project'
> ...
>
> **Connection map updated:**
>
> ```
> Frank Deluca (fixer)
>     ├── connected to → Lakeshore Holdings (plaza contract)
>     ├── connected to → Great Lakes Development (mentioned in April email!)
>     └── access to → Mayor's office (former employee, current informal influence)
> ```
>
> Wait—Great Lakes Development. That was also in your March interview. Your source mentioned them as getting favorable treatment. Now we have an email showing Frank is steering contracts their way too.
>
> You might have two shell companies, one fixer, and a pattern of corruption."

---

## Phase 4: The Pattern Emerges

**What Amara says:**
> "Show me everything we have on Great Lakes Development."

**What the agent does (invisible):**
```bash
meld node get "meld:entity/org/great-lakes-development" \
  --depth 2 \
  --include-backlinks
```

**What Amara sees:**
> "Here's what we have on Great Lakes Development:
>
> **From your March source interview:**
> - Receives favorable contract treatment (alleged)
> - Single source, marked as background
>
> **From the email FOIA (just discovered):**
> - 'Frank says Great Lakes is next in line for waterfront project' (Apr 15, 2025)
>
> **Connected entities:**
> - Frank Deluca (recommending their contracts)
> - Mayor's office (implicit, via Deluca)
>
> **What we DON'T have yet:**
> - Corporate registration (who owns it?)
> - Actual contracts they've received
> - Any connection to Victor Oduya or Lakeshore
>
> **My hypothesis:** Frank Deluca is the common thread. He's steering contracts to both Lakeshore Holdings and Great Lakes Development. The question is whether these companies share ownership—that would suggest a coordinated scheme rather than just favoritism.
>
> Want me to add 'Corporate records for Great Lakes Development' to the investigation's open questions?"

---

## What Would Have Happened Without Meld

Without the agent's memory:

1. Amara mentions Frank Deluca in March → writes it in a notebook → forgets
2. Amara reviews emails in August → sees "Per Frank's recommendation"
3. Amara thinks: "Who's Frank? Some city employee?" → doesn't connect to the fixer
4. Great Lakes Development never surfaces again
5. The pattern of multiple shell companies and one fixer remains hidden

**With meld**: A passing mention becomes documentary evidence because the agent remembered what Amara forgot.

---

## The Knowledge Graph After This Discovery

```
meld:entity/person/frank-deluca
├── [role] "Consultant/fixer"
├── [former_position] "Mayor's office"
├── [verificationStatus] "corroborated" (upgraded from single-source)
├── [meld:connectedTo] → meld:entity/org/lakeshore-holdings
│   └── [evidence] "City email FOIA - Feb 28, 2025"
├── [meld:connectedTo] → meld:entity/org/great-lakes-development
│   └── [evidence] "City email FOIA - Apr 15, 2025"
└── [meld:source] → meld:source/procurement-officer-former (March interview)

meld:entity/org/lakeshore-holdings
├── [contract] "Plaza renovation - $2.34M"
├── [meld:connectedTo] → Frank Deluca (via email)
└── [meld:possibleConnection] → Victor Oduya (alleged, single source)

meld:entity/org/great-lakes-development
├── [allegation] "Receives favorable treatment"
├── [meld:connectedTo] → Frank Deluca (via email)
└── [meld:pendingContract] "Waterfront project" (mentioned in email)

meld:claim/pattern-of-steering
├── [label] "Frank Deluca steering contracts to connected companies"
├── [evidence] → Lakeshore email (Feb 28)
├── [evidence] → Great Lakes email (Apr 15)
├── [source] → Former procurement officer
└── [verificationStatus] "corroborated"
```

---

## The Story That Emerged

What started as a single suspicious contract became:

1. **One fixer** (Frank Deluca) with access to city decision-makers
2. **Multiple shell companies** (Lakeshore Holdings, Great Lakes Development) receiving steered contracts
3. **Documentary evidence** (city emails) proving the steering
4. **Pattern of corruption** rather than isolated incident

The connection was there in March. It became visible in August because the agent never forgot.

---

## Verification Status Summary

| Claim | March Status | August Status |
|-------|--------------|---------------|
| Frank Deluca is a fixer | Single source | Corroborated (emails confirm influence) |
| Lakeshore contract was steered | Single source | Documented (email + no-bid records) |
| Great Lakes gets favorable treatment | Single source | Corroborated (email confirms pipeline) |
| Multiple companies, one scheme | Not hypothesized | Pattern visible |

**What changed**: Not new sources—new documents that connected to old sources. The agent's memory made the connection possible.
