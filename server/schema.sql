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
  task_type         TEXT,               -- branch <type> prefix only: feat|fix|chore|… [v2]

  -- loop effort
  fix_iterations    INTEGER,
  review_iterations INTEGER,
  gate_b            TEXT,                -- "passed" | skip reason
  followups         INTEGER,
  requirements_count INTEGER,           -- [v2]
  drift_events      INTEGER,            -- [v2]
  preview_verdict   TEXT,               -- PASS|FAIL|INCONCLUSIVE|null [v2]

  -- time & tokens (NULL when unmeasured — never 0)
  duration_min      INTEGER,
  est_duration_min  INTEGER,
  est_tokens        INTEGER,
  act_duration_min  INTEGER,
  act_tokens        INTEGER,
  tokens_input      INTEGER,            -- cache-excluded input tokens [v2]
  tokens_output     INTEGER,            -- output tokens (meaningful est ratio) [v2]

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
  repo_files_bucket     TEXT,           -- "<100" | "100-1k" | "1k-10k" | …
  primary_language      TEXT,           -- coarse family: js|ts|py|…
  is_monorepo           INTEGER,        -- 0/1
  churn_ratio           REAL,           -- 0..1 fraction of changed files touched before
  hotspot_concentration REAL,           -- 0..1 biggest-file share of changed lines
  dirs_touched          INTEGER,
  max_depth             INTEGER,

  -- user feedback (NULL unless the Phase-5 satisfaction prompt was answered)
  satisfaction      TEXT,               -- "yes" | "mostly" | "no"
  correctness       TEXT,               -- "yes" | "mostly" | "no"
  comment           TEXT                -- optional free-text note (<=500 chars)
);

-- Common dashboard access paths.
CREATE INDEX IF NOT EXISTS idx_runs_received_at    ON runs (received_at);
CREATE INDEX IF NOT EXISTS idx_runs_client_id      ON runs (client_id);
CREATE INDEX IF NOT EXISTS idx_runs_plugin_version ON runs (plugin_version);
