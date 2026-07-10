#!/usr/bin/env bash
# Drift-guard test for the telemetry receiver reference.
#
# Asserts server/ingest.mjs `COLUMNS` stays in lockstep with the scalar columns
# declared in server/schema.sql (everything except the server-managed
# `id`/`received_at` and the forward-compat `raw`). The two drifted once (v1
# COLUMNS silently dropping every v2 field on INSERT); this test makes a repeat
# mechanically impossible to miss. Also checks the `task_type` enum comment in
# schema.sql lists the split-out `deps` and catch-all `other` values (the 4th
# copy of the enum, otherwise only guarded by a reviewer note).
#
# Pure bash (bash-3.2-safe), no node required. Usage: tests/ingest-columns.test.sh
# Exit 0 = all passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/server/schema.sql"
INGEST="$ROOT/server/ingest.mjs"

PASS=0; FAIL=0
expect(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %-52s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-52s got=%s want=%s\n' "$1" "$2" "$3"; fi; }

echo "================ ingest-columns drift guard ================"
[ -f "$SCHEMA" ] || { echo "FAIL: $SCHEMA missing"; exit 1; }
[ -f "$INGEST" ] || { echo "FAIL: $INGEST missing"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Scalar column names from the CREATE TABLE runs (...) block: the first token of
# each column-definition line, excluding the server-managed and forward-compat
# columns. A column def line starts with an identifier then a type keyword.
awk '
  /CREATE TABLE[^(]*runs/ {inblock=1; next}
  inblock && /^\);/ {inblock=0}
  inblock {
    line=$0
    sub(/^[ \t]+/, "", line)
    # skip comment-only and blank lines
    if (line ~ /^--/ || line == "") next
    # first whitespace-delimited token is the column name
    name=line; sub(/[ \t].*/, "", name)
    if (name ~ /^[a-z_][a-z0-9_]*$/) print name
  }
' "$SCHEMA" | grep -vxE 'id|received_at|raw' | sort -u > "$T/schema_cols"

# COLUMNS array entries from ingest.mjs: the quoted strings inside the
# `const COLUMNS = [ ... ];` block.
awk '
  /const COLUMNS[ \t]*=/ {inarr=1}
  inarr {
    n=gsub(/"[a-z_][a-z0-9_]*"/, "&")  # no-op; keep line
    line=$0
    while (match(line, /"[a-z_][a-z0-9_]*"/)) {
      tok=substr(line, RSTART+1, RLENGTH-2)
      print tok
      line=substr(line, RSTART+RLENGTH)
    }
  }
  inarr && /\];/ {inarr=0}
' "$INGEST" | sort -u > "$T/ingest_cols"

sc="$(wc -l < "$T/schema_cols" | tr -d ' ')"
ic="$(wc -l < "$T/ingest_cols" | tr -d ' ')"
expect "schema scalar column count > 0"   "$([ "$sc" -gt 0 ] && echo ok)"  "ok"
expect "ingest COLUMNS count matches schema" "$ic" "$sc"

only_schema="$(comm -23 "$T/schema_cols" "$T/ingest_cols" | tr '\n' ',' | sed 's/,$//')"
only_ingest="$(comm -13 "$T/schema_cols" "$T/ingest_cols" | tr '\n' ',' | sed 's/,$//')"
expect "no schema column missing from ingest" "${only_schema:-none}" "none"
expect "no ingest column absent from schema"  "${only_ingest:-none}" "none"

# task_type enum comment (4th copy) lists the split-out + catch-all values.
ttline="$(grep -n 'task_type' "$SCHEMA" | head -1)"
expect "schema task_type comment lists deps"  "$(printf '%s' "$ttline" | grep -qi 'deps'  && echo ok)" "ok"
expect "schema task_type comment lists other" "$(printf '%s' "$ttline" | grep -qi 'other' && echo ok)" "ok"

echo "------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
