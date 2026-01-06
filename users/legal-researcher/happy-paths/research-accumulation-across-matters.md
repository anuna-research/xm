# Happy Path: Research Accumulates Across Matters

## Scenario

Elena researches promissory estoppel for one client matter. Six months later, a different client has a case involving the same doctrine. Her agent remembers the prior research and builds on it.

## Phase 1: Initial Research (January 2026)

### Matter: Henderson v. Pacific Finance

**What Elena says:**
> "New breach of contract case. Client relied on Pacific Finance's verbal promise to extend the loan term, but they didn't put it in writing. Pacific is now calling the loan. I need to research promissory estoppel in California—can we enforce an oral promise that contradicts the written loan agreement?"

**What the agent does (invisible):**
```bash
# Start session for this matter
meld session start --agent "claude-elena" \
  --purpose "Research: promissory estoppel for oral modification of loan" \
  --context "meld:matter/2026-henderson-v-pacific"

# Check for existing research on promissory estoppel (none found—first time)
meld query sparql "SELECT ?node WHERE {
  ?node skos:related <meld:doctrine/promissory-estoppel> .
  ?node meld:jurisdiction 'California'
}"
# Result: empty

# Agent researches from scratch, finds key cases, and records them:

# Record the doctrine
meld node create --type doctrine \
  --property "label=Promissory Estoppel" \
  --property "jurisdiction=California" \
  --property "elements=clear promise, reasonable reliance, foreseeable detriment, injustice avoidable only by enforcement" \
  --property "codification=Restatement (Second) of Contracts § 90"

# Record key cases found
meld node create --type case \
  --property "label=Aceves v. U.S. Bank (2011) 192 Cal.App.4th 218" \
  --property "citation=192 Cal.App.4th 218" \
  --property "court=California Court of Appeal" \
  --property "holding=Promissory estoppel requires clear and unambiguous promise; vague assurances insufficient" \
  --property "key_quote=A mere expression of intention, hope, or expectation is not a promise" \
  --link "meld:appliesTo:meld:doctrine/promissory-estoppel"

meld node create --type case \
  --property "label=Kajima/Ray Wilson v. LA County MTA (2000) 23 Cal.4th 305" \
  --property "citation=23 Cal.4th 305" \
  --property "court=California Supreme Court" \
  --property "holding=Promissory estoppel can create binding contract even without consideration" \
  --link "meld:appliesTo:meld:doctrine/promissory-estoppel"

meld node create --type case \
  --property "label=Granadino v. Wells Fargo Bank (2015) 236 Cal.App.4th 411" \
  --property "citation=236 Cal.App.4th 411" \
  --property "holding=Detrimental reliance must be substantial; mere inconvenience insufficient" \
  --link "meld:cites:meld:case/aceves-v-us-bank" \
  --link "meld:appliesTo:meld:doctrine/promissory-estoppel"

# Record the analysis for this matter (matter-specific graph)
meld node create --type argument \
  --graph "meld:graph/matter/2026-henderson-v-pacific" \
  --property "label=Promissory estoppel overcomes written agreement" \
  --property "content=Oral promise to extend loan term enforceable despite integration clause because: (1) promise was clear and specific (2) reliance was foreseeable (3) client's detriment substantial" \
  --link "meld:supportedBy:meld:case/kajima-v-mta" \
  --link "meld:distinguishes:meld:case/aceves-v-us-bank"

meld session end --summary "Full promissory estoppel research completed. Kajima strongest authority. Must distinguish Aceves on clarity of promise."
```

**What Elena sees:**
> "I've completed the promissory estoppel research. Here's what I found:
>
> **The doctrine** (California): Four elements—clear promise, reasonable reliance, foreseeable detriment, injustice avoidable only by enforcement.
>
> **Best authority for us:**
> - *Kajima/Ray Wilson v. LA County MTA* (2000) - California Supreme Court held promissory estoppel can create binding contract even without consideration
>
> **Challenge we'll face:**
> - *Aceves v. U.S. Bank* (2011) - Requires 'clear and unambiguous' promise; vague assurances don't count
>
> **My analysis:** The loan officer's statement 'we'll extend your loan, don't worry' is borderline. We need facts showing it was specific—dates, terms, written follow-up. The stronger our promise evidence, the better we distinguish Aceves.
>
> Want me to draft the promissory estoppel section of the complaint?"

---

## Phase 2: Matter Resolves (April 2026)

Henderson v. Pacific Finance settles. The promissory estoppel argument was successful in getting Pacific to negotiate.

---

## Phase 3: New Matter, Same Doctrine (July 2026)

### Matter: Okonkwo v. Bay Area Development

**What Elena says:**
> "Got a new case. Client was promised a construction loan would be converted to permanent financing once the building was complete. They completed the building, but the bank refused to convert. Classic promissory estoppel situation. What do we know?"

**What the agent does (invisible):**
```bash
# Start session
meld session start --agent "claude-elena" \
  --purpose "Research: promissory estoppel for loan conversion promise" \
  --context "meld:matter/2026-okonkwo-v-bayarea"

# Query existing promissory estoppel research
meld query sparql "SELECT ?case ?holding ?citation WHERE {
  ?case meld:appliesTo <meld:doctrine/promissory-estoppel> .
  ?case meld:jurisdiction 'California' .
  ?case meld:holding ?holding .
  ?case meld:citation ?citation
} ORDER BY ?citation"

# Found: Aceves, Kajima, Granadino from January research

# Get the doctrine summary
meld node get "meld:doctrine/promissory-estoppel"

# Check for similar fact patterns
meld query sparql "SELECT ?argument ?matter WHERE {
  ?argument meld:appliesTo <meld:doctrine/promissory-estoppel> .
  ?argument skos:related ?matter .
  ?matter a meld:Matter
}"
# Found: Henderson matter argument
```

**What Elena sees:**
> "Great news—we have substantial prior research on promissory estoppel from the Henderson v. Pacific Finance matter in January. Here's what we know:
>
> **California elements:** Clear promise, reasonable reliance, foreseeable detriment, injustice avoidable only by enforcement.
>
> **Our case library:**
> - *Kajima/Ray Wilson v. LA County MTA* (2000) 23 Cal.4th 305 - Supreme Court authority that promissory estoppel can create binding contract
> - *Aceves v. U.S. Bank* (2011) 192 Cal.App.4th 218 - Requires clear and unambiguous promise
> - *Granadino v. Wells Fargo* (2015) 236 Cal.App.4th 411 - Detrimental reliance must be substantial
>
> **Prior argument structure:** In Henderson, we argued the oral loan extension promise was enforceable. We distinguished Aceves by showing specific dates and terms were discussed.
>
> **For this case:** The facts look stronger—completing a building is much more substantial reliance than what we had in Henderson. The bank's promise to convert financing seems clearer too. Want me to adapt the Henderson analysis or search for additional authority on construction lending specifically?"

**What Elena says:**
> "The Henderson analysis is a great starting point. But search for any California cases specifically involving construction-to-permanent loan conversions. That would be even more on point."

**What the agent does (invisible):**
```bash
# Search for additional cases (agent uses external legal research, finds new case)
# Record the new case in the firm knowledge base

meld node create --type case \
  --property "label=Phillippe v. Shapell Industries (1987) 43 Cal.3d 1247" \
  --property "citation=43 Cal.3d 1247" \
  --property "court=California Supreme Court" \
  --property "holding=Builder's reliance on lender's commitment letter for construction financing, even if conditional, may support promissory estoppel" \
  --property "key_fact=Builder completed construction relying on lender's letter; lender refused permanent financing" \
  --link "meld:appliesTo:meld:doctrine/promissory-estoppel" \
  --link "meld:citedBy:meld:case/kajima-v-mta"

# Link to existing research
meld link create --source "meld:case/phillippe-v-shapell" \
  --predicate "skos:related" \
  --target "meld:case/kajima-v-mta" \
  --property "relationship=Both California Supreme Court, both favorable on promissory estoppel"
```

**What Elena sees:**
> "Found an excellent case: *Phillippe v. Shapell Industries* (1987) 43 Cal.3d 1247—California Supreme Court. Almost identical facts:
>
> **Facts:** Builder completed construction relying on lender's commitment letter. Lender refused permanent financing. Builder sued on promissory estoppel.
>
> **Holding:** Builder's reliance on lender's commitment letter, even if conditional, may support promissory estoppel when the builder has substantially performed.
>
> **Why this is perfect:** Supreme Court authority, construction lending context, substantial reliance through completion of the building.
>
> I've added this to our case library and linked it to our promissory estoppel research. Combined with Kajima, you have two Supreme Court cases directly supporting the argument.
>
> Want me to draft a complaint using this authority?"

---

## Phase 4: Research Benefits Colleague (October 2026)

David, a junior associate, picks up a new case involving promissory estoppel.

### Matter: Martinez v. Golden State Bank

**What David says (to his agent):**
> "I have a promissory estoppel case in California. What should I know?"

**What David's agent does (invisible):**
```bash
meld query context --focus "meld:doctrine/promissory-estoppel" \
  --max-tokens 6000 \
  --include doctrine,case,argument
```

**What David sees:**
> "The firm has extensive promissory estoppel research. Here's the summary:
>
> **California elements:**
> Clear promise, reasonable reliance, foreseeable detriment, injustice avoidable only by enforcement.
>
> **Key cases in our library:**
>
> | Case | Citation | Why it matters |
> |------|----------|----------------|
> | *Kajima/Ray Wilson* | 23 Cal.4th 305 | Supreme Court: PE can create binding contract |
> | *Phillippe v. Shapell* | 43 Cal.3d 1247 | Supreme Court: Construction lending context |
> | *Aceves v. U.S. Bank* | 192 Cal.App.4th 218 | Requires clear promise (potential obstacle) |
> | *Granadino v. Wells Fargo* | 236 Cal.App.4th 411 | Reliance must be substantial |
>
> **Prior firm matters:**
> - Henderson v. Pacific Finance (Jan 2026, settled) - Oral loan extension promise
> - Okonkwo v. Bay Area Development (Jul 2026, pending) - Construction loan conversion
>
> Elena developed the analysis for these. The key strategic insight: distinguish Aceves by showing promise was specific with clear terms, not just vague assurances.
>
> What are the facts of your case? I can help you map them to this framework."

---

## What Accumulated

```
meld:graph/firm/smith-jones
│
├── meld:doctrine/promissory-estoppel
│   ├── [elements] "clear promise, reasonable reliance..."
│   ├── [jurisdiction] "California"
│   └── linked to 4 cases
│
├── meld:case/kajima-v-mta
│   ├── [holding] "PE can create binding contract..."
│   └── [citedBy] phillippe-v-shapell
│
├── meld:case/phillippe-v-shapell    ← Added July 2026
│   ├── [holding] "Construction lending reliance..."
│   └── [cites] kajima-v-mta
│
├── meld:case/aceves-v-us-bank
│   └── [holding] "Requires clear promise..."
│
└── meld:case/granadino-v-wells-fargo
    └── [cites] aceves-v-us-bank

meld:graph/matter/2026-henderson    (client-specific, restricted)
└── meld:argument/henderson-pe-argument
    └── specific strategy for that case

meld:graph/matter/2026-okonkwo      (client-specific, restricted)
└── meld:argument/okonkwo-pe-argument
    └── specific strategy for that case
```

## The Accumulation Effect

| Time | Event | Knowledge Added |
|------|-------|-----------------|
| Jan 2026 | Henderson matter | Doctrine + 3 core cases |
| Jul 2026 | Okonkwo matter | 1 additional case (Phillippe) |
| Oct 2026 | Martinez matter | Zero research time—David inherits everything |

**Elena did research once. David benefits forever.**

General legal knowledge (doctrines, cases, citations) flows to the firm graph. Client-specific strategy stays isolated in matter graphs. Everyone's agent gets smarter without anyone maintaining a database.
