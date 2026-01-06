# Happy Path: Share Project Knowledge with Contractor

## Scenario

A developer needs to grant a contractor's LLM agent access to project knowledge for a two-week engagement. The contractor should be able to read project facts but not modify them or access other projects.

## Preconditions

- Developer has admin capability for the project graph
- Project entity exists with accumulated knowledge
- Contractor will use their own LLM agent (different from developer's)

## Flow

```bash
# 1. Developer checks current project knowledge
meld node get "meld:entity/acme-api" --depth 1

# Response:
{
  "ok": true,
  "data": {
    "node": {
      "id": "meld:entity/acme-api",
      "type": "entity",
      "properties": {"name": "acme-api", "kind": "repository"}
    },
    "links": [
      {"predicate": "meld:uses", "target": "meld:entity/fastapi"},
      {"predicate": "meld:uses", "target": "meld:entity/postgresql"},
      {"predicate": "meld:dependsOn", "target": "meld:entity/auth-service"}
    ]
  }
}

# 2. Developer creates a read-only capability scoped to project graph
meld cap create --graphs "meld:graph/project/acme-api,meld:graph/public" \
  --permissions read \
  --expires "2026-01-20"

# Response:
{
  "ok": true,
  "data": {
    "cap_ref": "meld:cap/contractor-abc789",
    "graphs": ["meld:graph/project/acme-api", "meld:graph/public"],
    "permissions": ["read"],
    "expires": "2026-01-20T00:00:00Z"
  }
}

# 3. Developer shares cap_ref with contractor (out of band - email, secure message, etc.)
# cap_ref: meld:cap/contractor-abc789

# 4. Contractor's agent uses the capability to query project knowledge
# (From contractor's agent perspective)
meld query sparql --cap "meld:cap/contractor-abc789" \
  "SELECT ?dep ?label WHERE {
    <meld:entity/acme-api> meld:dependsOn ?dep .
    ?dep rdfs:label ?label
  }"

# Response:
{
  "ok": true,
  "data": {
    "head": {"vars": ["dep", "label"]},
    "results": {
      "bindings": [
        {
          "dep": {"type": "uri", "value": "meld:entity/auth-service"},
          "label": {"type": "literal", "value": "auth-service"}
        }
      ]
    }
  }
}

# 5. Contractor's agent tries to write (should fail)
meld node create --cap "meld:cap/contractor-abc789" \
  --type fact \
  --property "content=Some discovery"

# Response:
{
  "ok": false,
  "error": {
    "code": "PERMISSION_DENIED",
    "message": "Capability lacks write permission",
    "details": {"required": "write", "granted": ["read"]}
  }
}

# 6. Contractor's agent tries to access another project (should fail)
meld query sparql --cap "meld:cap/contractor-abc789" \
  "SELECT ?s WHERE { GRAPH <meld:graph/project/secret-project> { ?s ?p ?o } }"

# Response (empty - query is scoped to allowed graphs only):
{
  "ok": true,
  "data": {
    "head": {"vars": ["s"]},
    "results": {"bindings": []}
  }
}

# 7. After engagement ends, developer revokes capability
meld cap revoke "meld:cap/contractor-abc789"

# Response:
{
  "ok": true,
  "data": {
    "revoked": "meld:cap/contractor-abc789",
    "revoked_at": "2026-01-21T09:00:00Z"
  }
}

# 8. Contractor's agent can no longer use the capability
meld query sparql --cap "meld:cap/contractor-abc789" \
  "SELECT ?s WHERE { ?s ?p ?o }"

# Response:
{
  "ok": false,
  "error": {
    "code": "INVALID_CAPABILITY",
    "message": "Capability has been revoked"
  }
}
```

## Postconditions

- Contractor's agent had read access for the engagement duration
- Write attempts were blocked
- Access to other projects was prevented
- Capability was revoked after engagement
- All access was auditable

## What the Developer Gained

- Shared project knowledge without giving full access
- Maintained control over what could be read vs written
- Time-limited access that required no cleanup (auto-expires)
- Clean revocation when engagement ended early
- Peace of mind: capability model means no ambient authority
