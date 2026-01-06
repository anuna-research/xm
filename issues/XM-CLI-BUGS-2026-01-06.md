# XM CLI Bug Report - 2026-01-06

Bugs discovered while testing xm CLI as an LLM agent.

## Critical Issues

### 1. JSON output corrupted by Guile compilation notes
**Severity**: Critical
**Commands affected**: All commands with `--json` flag

The `;;; note: source file...` Guile compilation warning is printed to stdout before JSON output, breaking machine parsing.

**Reproduction**:
```bash
./bin/xm --json session list
```

**Output**:
```
;;; note: source file /Users/.../store.scm
;;;       newer than compiled ...
{"ok":true,"data":...}
```

**Expected**: Only valid JSON on stdout. Compilation notes should go to stderr or be suppressed.

**Impact**: LLM agents cannot reliably parse JSON output. This is a blocking issue for automated use.

### 2. JSON structure uses arrays instead of objects
**Severity**: High
**Commands affected**: `session list`, possibly others

JSON output uses nested arrays with string keys instead of proper objects:
```json
["sessions", {...}, {...}]
["filters", {"agent":false}]
```

**Expected**: Proper object structure:
```json
{"sessions": [...], "filters": {...}}
```

---

## Medium Issues

### 3. `graph list -v` doesn't show triple counts
**Severity**: Medium
**Command**: `xm graph list -v`

The verbose flag is supposed to show triple counts per graph, but output is identical to non-verbose mode.

**Reproduction**:
```bash
./bin/xm graph list -v
```

**Output**:
```
Named Graphs:

  xm:graph/sessions
  xm:graph/public

Total: 2 graphs
```

**Expected**: Triple counts should appear when `-v` is specified.

### 4. Node create output inconsistent newline
**Severity**: Low
**Command**: `xm node create`

Some node create outputs have leading newline, others don't:
```
  id: ...     # has leading spaces, no newline
```

vs

```
  id: ...     # sometimes has different formatting
```

---

## Usability Issues

### 5. Link create option names not intuitive
**Severity**: Low
**Command**: `xm link create`

- Uses `--from` and `--to` instead of `-s`/`-t` (source/target)
- Uses `--predicate` instead of `-r` (relation)

Error messages correctly point to the expected options, but documentation should be clearer.

### 6. Node type case sensitivity not documented
**Severity**: Low
**Command**: `xm node create -t <type>`

Types must be lowercase (`entity` not `Entity`). Error message is helpful but behavior should be documented.

---

## Syntax Errors Fixed During Testing

The following syntax errors were found and fixed in the Guile source:

1. **session.scm**: Missing 2 closing parentheses in `cmd-session-resume` and `cmd-session-history`
2. **cap.scm**: Missing 1 closing parenthesis in `cmd-cap-inspect` and `revoke-derived-capabilities`
3. **daemon.scm**: Used `define` instead of `define*` for keyword argument in `daemon-start`

These have been corrected but suggest need for better Scheme linting in CI.

---

## Environment

- Platform: macOS (Darwin 24.5.0)
- Guile: 3.0
- Test date: 2026-01-06
