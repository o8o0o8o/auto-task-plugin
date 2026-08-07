-- auto-task telemetry — Turso / libSQL (SQLite) schema.
--
-- REFERENCE, UNDEPLOYED. This is the table the reference ingest handler
-- (server/ingest.mjs) writes to. Apply it to a Turso database you create
-- (`turso db shell <db> < server/schema.sql`) before deploying the handler.
--
-- WRITE-ONLY, FORWARD-ONLY store (for now). The client fire-and-forgets rows;
-- there is no update/delete path and no read path in this reference.
--
-- SCHEMA EVOLUTION. Every row carries `schema_version` (the client's payload
-- schema). This column is the migration anchor: to add a metric later, bump the
-- client's SCHEMA_VERSION, then `ALTER TABLE runs ADD COLUMN <new> ...` here as a
-- NULLABLE column (never rewrite or drop columns — old rows must keep parsing).
-- Consumers filter/branch on `schema_version` to interpret a row correctly.
-- SQLite/libSQL has no BOOLEAN type: `flaky` / `tests_added` are stored as
-- INTEGER 0/1 (the handler coerces JSON booleans).

CREATE TABLE IF NOT EXISTS runs (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  -- server-side ingest timestamp (the client deliberately sends no wall-clock).
  received_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),

  -- identity / environment
  client_id         TEXT    NOT NULL,   -- random, resettable install id (no PII)
  plugin_version    TEXT    NOT NULL,
  os                TEXT,
  schema_version    INTEGER NOT NULL,

  -- environment (schema_version 2+)
  model               TEXT,             -- e.g. "claude-opus-4-8"
  claude_code_version TEXT,             -- e.g. "2.1.205"

  -- outcome / effort
  terminal_state    TEXT,               -- always "done" for a completed run
  tier              TEXT,
  tier_initial      TEXT,
  difficulty        INTEGER,            -- effort rubric D (0-8)  [v2]
  risk              INTEGER,            -- effort rubric R (0-8)  [v2]
  escalations       INTEGER,
  task_type         TEXT,               -- bounded enum, branch <type> prefix only: feat|fix|deps|refactor|docs|chore|cleanup|other [v2]

  -- loop effort
  fix_iterations    INTEGER,
  review_iterations INTEGER,           -- rounds that REOPENED the loop (graded count)
  review_rounds     INTEGER,           -- [v7] Phase-4 review rounds RUN, reopening or
                                       -- not. Distinct from review_iterations above:
                                       -- comparing the two separates "the review keeps
                                       -- finding real breaches" from "the review keeps
                                       -- running and finding nothing". 0 is a real
                                       -- measurement; NULL means the row cannot say.
                                       -- NULL is NOT a pre-v7 marker: pre-v7 rows carry
                                       -- it, and so does a v7 row whose sender state
                                       -- predates rounds[]. So schema_version < 7 is
                                       -- NARROWER than "IS NULL" and is no substitute
                                       -- for it -- exclude NULLs, never coalesce them
                                       -- to 0, or a pooled aggregate reports a
                                       -- review-volume drop that never happened.
  gate_b            TEXT,                -- "passed" | skip reason
  followups         INTEGER,
  requirements_count INTEGER,           -- [v2]
  drift_events      INTEGER,            -- [v2]
  preview_verdict   TEXT,               -- PASS|FAIL|INCONCLUSIVE|null [v2]
  external_status   TEXT,               -- Phase-8 external-change status enum | null [v3]

  -- time & tokens (NULL when unmeasured — never 0)
  duration_min      INTEGER,            -- SEMANTICS + NULLABILITY CHANGED IN v6:
                                        -- MEASURED from the sender's hook-stamped
                                        -- run clock, and NULL when the span was
                                        -- rejected as implausible (negative, >12h).
                                        -- NOT null merely when unmeasured: with no
                                        -- clock the sender falls back to the pre-v6
                                        -- history derivation, which still yields 0
                                        -- on unusable history. Treat 0 as suspect
                                        -- in every version.
                                        -- v1-v5 rows were derived from model-written
                                        -- history timestamps and were ALWAYS a
                                        -- number (falling back to 0), so a v5 `0`
                                        -- reads like a real fast run: branch on
                                        -- schema_version before treating any
                                        -- duration as measured. Same for
                                        -- act_duration_min below.
  est_duration_min  INTEGER,
  est_tokens        INTEGER,            -- SEMANTICS CHANGED IN v5: predicted OUTPUT
                                        -- tokens, comparable to tokens_output below.
                                        -- v1-v4 rows carry a cache-INCLUSIVE total
                                        -- instead, so the est/act token ratio must
                                        -- branch on schema_version before pooling
                                        -- v4 and v5 rows (the two are ~100x apart).
  act_duration_min  INTEGER,
  act_tokens        INTEGER,            -- measured grand total (input+output+cache);
                                        -- cache_read-dominated, so it is recorded but
                                        -- is NOT the est-ratio numerator. Unchanged.
  tokens_input      INTEGER,            -- cache-excluded input tokens [v2]
  tokens_output     INTEGER,            -- measured output tokens; the est-ratio actual,
                                        -- paired with est_tokens as of v5 [v2]

  -- quality signals
  defects_early     INTEGER,
  defects_late      INTEGER,
  flaky             INTEGER,             -- 0/1
  tests_added       INTEGER,             -- 0/1
  diff_loc          INTEGER,
  files_changed     INTEGER,             -- [v2]
  first_pass_ac     REAL,
  checks_run        INTEGER,
  checks_failed     INTEGER,

  -- project size + change heat (anonymous buckets/numbers only — no paths) [v2]
  -- FROZEN as of schema_version 4 (v0.23.0): the client no longer EMITS these —
  -- at the current install base they can't reach statistical power as reporting
  -- dimensions, and slicing a small ledger by them courts winner's-curse false
  -- discoveries. Columns are RETAINED (never drop — old v2/v3 rows keep parsing);
  -- v4+ rows simply store NULL here. Re-enable the client merge to resume.
  repo_files_bucket     TEXT,           -- [v2, frozen v4] "<100" | "100-1k" | "1k-10k" | …
  primary_language      TEXT,           -- [v2, frozen v4] coarse family: js|ts|py|…
  is_monorepo           INTEGER,        -- [v2, frozen v4] 0/1
  churn_ratio           REAL,           -- [v2, frozen v4] 0..1 fraction of changed files touched before
  hotspot_concentration REAL,           -- [v2, frozen v4] 0..1 biggest-file share of changed lines
  dirs_touched          INTEGER,        -- [v2, frozen v4]
  max_depth             INTEGER,        -- [v2, frozen v4]

  -- user feedback (NULL unless the Phase-5 satisfaction prompt was answered)
  satisfaction      TEXT,               -- "yes" | "mostly" | "no"
  correctness       TEXT,               -- "yes" | "mostly" | "no"
  comment           TEXT,               -- optional free-text note (<=500 chars)

  -- forward-compat: the full JSON payload exactly as received. Captures nested or
  -- future fields (e.g. tokens_by_skill) before they get a dedicated column, so a
  -- newer client never silently loses data against an older schema. [v2]
  raw               TEXT
);

-- Common dashboard access paths.
CREATE INDEX IF NOT EXISTS idx_runs_received_at    ON runs (received_at);
CREATE INDEX IF NOT EXISTS idx_runs_client_id      ON runs (client_id);
CREATE INDEX IF NOT EXISTS idx_runs_plugin_version ON runs (plugin_version);
