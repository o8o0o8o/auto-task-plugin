// auto-task telemetry — reference ingest handler (Turso / libSQL).
//
// REFERENCE, UNDEPLOYED. A minimal, portable, web-standard `fetch` handler that
// accepts the anonymized telemetry payload POSTed by hooks/send-telemetry.sh and
// INSERTs it into the `runs` table (see server/schema.sql). It is intentionally
// small: this is the "we only write for now" ingest, not a full API.
//
// PORTABILITY. The default export is a `(request: Request) => Promise<Response>`
// fetch handler — the shape used by Cloudflare Workers, Deno Deploy, Vercel Edge
// Functions, Netlify Edge, and Bun. See server/README.md for per-platform wiring.
//
// SECURITY — YOURS TO HARDEN before exposing publicly. This reference validates
// only the payload SHAPE. It does NOT authenticate callers or rate-limit. Add an
// ingest token / WAF / rate limit / body-size cap appropriate to your deployment.
//
// libSQL API NOTE: written against the stable `@libsql/client` API
// (`createClient({url, authToken})` + `execute({sql, args})`). Verify against the
// current libSQL docs when you deploy — this file has never been run in CI here.

import { createClient } from "@libsql/client/web";

// Column order MUST match the INSERT below and stays in lockstep with
// server/schema.sql and the client payload (hooks/send-telemetry.sh).
// Scalar columns, in schema.sql declaration order (everything except the
// server-managed `id`/`received_at` and the forward-compat `raw`, which is
// appended separately in the INSERT below). tests/ingest-columns.test.sh
// asserts this list stays in lockstep with server/schema.sql.
const COLUMNS = [
  "client_id", "plugin_version", "os", "schema_version",
  "model", "claude_code_version",
  "terminal_state", "tier", "tier_initial", "difficulty", "risk", "escalations", "task_type",
  "fix_iterations", "review_iterations", "gate_b", "followups", "requirements_count",
  "drift_events", "preview_verdict", "external_status",
  "duration_min", "est_duration_min", "est_tokens", "act_duration_min", "act_tokens",
  "tokens_input", "tokens_output",
  "defects_early", "defects_late", "flaky", "tests_added", "diff_loc", "files_changed",
  "first_pass_ac", "checks_run", "checks_failed",
  "repo_files_bucket", "primary_language", "is_monorepo", "churn_ratio",
  "hotspot_concentration", "dirs_touched", "max_depth",
  "satisfaction", "correctness", "comment",
];

// Minimal shape validation: the three NOT NULL identity/env fields must be present.
const REQUIRED = ["client_id", "plugin_version", "schema_version"];

let _db = null;
function db(env) {
  // env: an object exposing TURSO_DATABASE_URL / TURSO_AUTH_TOKEN. On most
  // platforms that is `process.env`; on Cloudflare it is the Worker `env` arg.
  if (_db) return _db;
  const url = env.TURSO_DATABASE_URL;
  const authToken = env.TURSO_AUTH_TOKEN;
  if (!url) throw new Error("TURSO_DATABASE_URL is not set");
  _db = createClient({ url, authToken });
  return _db;
}

function toArg(key, value) {
  if (value === undefined || value === null) return null;
  // SQLite has no boolean — coerce the boolean payload fields to 0/1.
  // is_monorepo arrives as a JSON boolean from repo-metrics.sh (--argjson mono).
  if (key === "flaky" || key === "tests_added" || key === "is_monorepo") return value ? 1 : 0;
  return value;
}

export async function handle(request, env = (globalThis.process && globalThis.process.env) || {}) {
  if (request.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  let payload;
  try {
    payload = await request.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    return json({ error: "payload must be a JSON object" }, 400);
  }
  for (const k of REQUIRED) {
    if (payload[k] === undefined || payload[k] === null || payload[k] === "") {
      return json({ error: `missing required field: ${k}` }, 400);
    }
  }

  // `raw` is appended last: the full payload as received (forward-compat), so a
  // newer client's not-yet-columned fields survive. Not part of COLUMNS (which
  // mirrors the scalar schema); the drift test only checks COLUMNS vs schema.
  const insertCols = [...COLUMNS, "raw"];
  const placeholders = insertCols.map(() => "?").join(", ");
  const sql = `INSERT INTO runs (${insertCols.join(", ")}) VALUES (${placeholders})`;
  const args = [...COLUMNS.map((k) => toArg(k, payload[k])), JSON.stringify(payload)];

  try {
    await db(env).execute({ sql, args });
  } catch (err) {
    return json({ error: "ingest failed", detail: String(err && err.message || err) }, 502);
  }

  // 202 Accepted — fire-and-forget write acknowledged.
  return json({ ok: true }, 202);
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Default export = the fetch handler (Workers/Deno/Vercel-Edge/Bun shape).
export default { fetch: handle };
