# auto-task telemetry — ingest server (reference, undeployed)

This directory is a **reference implementation** of the remote-telemetry ingest
endpoint. It is **committed but not deployed** and is **not part of the plugin
runtime** — the plugin (bash hooks + skills) never imports it. Deploy it yourself
when you want to start collecting the opt-in anonymous rows the client sends.

```
client (hooks/send-telemetry.sh)  --HTTPS POST JSON-->  ingest.mjs  --libSQL-->  Turso
```

The client never holds a database credential; only this server does.

## Files

| File | What it is |
|---|---|
| `ingest.mjs` | A web-standard `fetch` handler (`export default { fetch }`) that validates the payload shape and `INSERT`s one row. |
| `schema.sql` | The Turso/libSQL (SQLite) `runs` table the handler writes to. |
| `package.json` | Declares the one dependency, `@libsql/client`. |

> **libSQL API caveat.** `ingest.mjs` is written against the stable `@libsql/client`
> API but has not been run in this repo's CI. Verify the import/usage against the
> current libSQL docs when you deploy.

## The payload contract

`send-telemetry.sh` POSTs a single flat JSON object. It is **anonymous by
construction** — it contains no task text, branch, repo path, base SHA, or
wall-clock timestamp. Fields:

| Field | Type | Notes |
|---|---|---|
| `client_id` | string | Random, resettable install id (no PII). **Required.** |
| `plugin_version` | string | e.g. `"0.6.0"`. **Required.** |
| `os` | string | `uname -s` (e.g. `"Darwin"`, `"Linux"`). |
| `schema_version` | number | Payload schema version (migration anchor). **Required.** |
| `terminal_state` | string | Always `"done"`. |
| `tier` / `tier_initial` | string | Effort tier, final / initial. |
| `escalations` | number | Effort escalations. |
| `fix_iterations` / `review_iterations` | number | Loop counts. |
| `gate_b` | string | `"passed"` or a skip reason. |
| `followups` | number | Parked follow-up count. |
| `duration_min` | number | Wall-clock (from history timestamps). |
| `est_duration_min` / `est_tokens` | number \| null | Pre-run estimate (null when unmeasured). |
| `act_duration_min` / `act_tokens` | number \| null | Measured actuals. |
| `defects_early` / `defects_late` | number | Findings caught early / late. |
| `flaky` / `tests_added` | boolean | Stored as 0/1. |
| `diff_loc` | number | Lines added+removed. |
| `first_pass_ac` | number \| null | Share of ACs green on first self-verify. |
| `checks_run` / `checks_failed` | number | Checks-manifest tally. |
| `satisfaction` / `correctness` | string \| null | Phase-5 answers (`"yes"`/`"mostly"`/`"no"`), null if not asked. |
| `model` | string \| null | Model id, e.g. `"claude-opus-4-8"`. [v2] |
| `claude_code_version` | string \| null | Claude Code CLI version. [v2] |
| `difficulty` / `risk` | number | Effort rubric D / R (0–8). [v2] |
| `task_type` | string | Branch `<type>` prefix only: `feat\|fix\|deps\|refactor\|docs\|chore\|cleanup\|other`. [v2] |
| `requirements_count` | number | Dissected-requirement count. [v2] |
| `drift_events` | number | Blast-radius drift events. [v2] |
| `preview_verdict` | string \| null | `PASS\|FAIL\|INCONCLUSIVE`, null if no preview phase. [v2] |
| `external_status` | string \| null | Phase-8 external-change status (`declared\|awaiting-external\|applied-verified\|applied-unverified\|failed\|none\|skipped-disabled`); `none` when a run evaluated external actions and had none to apply, `null` when the `external` object is absent (older runs / no external phase reached). [v3] |
| `tokens_input` / `tokens_output` | number \| null | Cache-excluded input / output tokens. [v2] |
| `files_changed` | number | Files in the run diff. [v2] |
| `comment` | string \| null | Optional Phase-5 free-text note (≤500 chars) — the one **user-authored, non-derived** field; consent-gated. [v2] |
| `repo_files_bucket`, `primary_language`, `is_monorepo`, `churn_ratio`, `hotspot_concentration`, `dirs_touched`, `max_depth` | mixed | Anonymized repo-shape block from `repo-metrics.sh` (coarse buckets/numbers only — no paths). [v2] |

`tokens_by_skill` is also POSTed but has no dedicated column — it is preserved in the `raw` column. The `[v2]` fields require `schema_version` ≥ 2; the `[v3]` fields (`external_status`) require `schema_version` ≥ 3.

Every request carries `Authorization: Bearer <telemetry_ingest_token>` when the token is non-empty (the bundled default token is non-empty, so this header is sent by default). A deployed endpoint should validate it (see "Harden" below).

Example:

```bash
curl -sS -X POST "$TELEMETRY_ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TELEMETRY_INGEST_TOKEN" \
  --data '{"client_id":"9f3a...","plugin_version":"0.6.0","os":"Darwin","schema_version":2,"terminal_state":"done","tier":"standard","duration_min":42,"satisfaction":"yes","correctness":"yes"}'
```

## Deploy

1. **Create the database and apply the schema:**
   ```bash
   turso db create auto-task-telemetry
   turso db shell auto-task-telemetry < server/schema.sql
   turso db show auto-task-telemetry --url            # -> TURSO_DATABASE_URL
   turso db tokens create auto-task-telemetry         # -> TURSO_AUTH_TOKEN
   ```
2. **Set env vars** on your platform: `TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`.
3. **Deploy `ingest.mjs`** to any `fetch`-handler host:
   - **Cloudflare Workers / Deno Deploy / Bun / Vercel Edge / Netlify Edge:** the
     default export `{ fetch }` is the handler. On Cloudflare, read creds from the
     Worker `env` arg: `export default { fetch: (req, env) => handle(req, env) }`.
   - **Node (server or Vercel Serverless):** wrap `handle` in an adapter that
     builds a `Request` and returns the `Response` (creds come from `process.env`).
4. **Point the client at it:** set `telemetry_endpoint` to the deployed **https**
   URL and `telemetry_enabled: true` in the auto-task settings (project or global).

## Harden before public exposure

This reference validates only the payload shape. The client already sends
`Authorization: Bearer <telemetry_ingest_token>` on every request (the bundled
default token is public/write-only by design), so before exposing the endpoint,
**validate that ingest token** (reject requests whose bearer token doesn't match
your configured value) — plus add a body-size cap and rate limiting. The store is
write-only and forward-only; there is no read/delete path here.
