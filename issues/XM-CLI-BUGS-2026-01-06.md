# XM CLI Bug Report - 2026-01-06

Bugs discovered while testing xm CLI as an LLM agent.

## Critical Issues

### 1. JSON output corrupted by Guile compilation notes [FIXED]
**Severity**: Critical
**Commands affected**: All commands with `--json` flag
**Status**: FIXED

The `;;; note: source file...` Guile compilation warning was printed to stdout before JSON output, breaking machine parsing.

**Fix**: Modified `bin/xm` to filter Guile compilation notes from stderr using process substitution.

### 2. JSON structure uses arrays instead of objects [FIXED]
**Severity**: High
**Commands affected**: `session list`, possibly others
**Status**: FIXED

JSON output was using nested arrays with string keys instead of proper objects.

**Fix**: Modified `output.scm` to properly detect alists and serialize them as JSON objects. Also fixed double-wrapping issue where commands were wrapping data with `{ok, data}` and then `output-result` was adding another wrapper.

---

## Medium Issues

### 3. `graph list -v` doesn't show triple counts [FIXED]
**Severity**: Medium
**Command**: `xm graph list -v`
**Status**: FIXED

The verbose flag was not showing triple counts because `-v` is parsed as a global option, but the graph list command was only checking command-specific options.

**Fix**: Modified `graph.scm` to check both `opts` and `global-opts` for the verbose flag.

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
