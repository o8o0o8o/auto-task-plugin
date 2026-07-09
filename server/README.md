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
| `plugin_version` | string | e.g. `"0.3.0"`. **Required.** |
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

Example:

```bash
curl -sS -X POST "$TELEMETRY_ENDPOINT" \
  -H 'Content-Type: application/json' \
  --data '{"client_id":"9f3a...","plugin_version":"0.3.0","os":"Darwin","schema_version":1,"terminal_state":"done","tier":"standard","duration_min":42,"satisfaction":"yes","correctness":"yes"}'
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

This reference validates only the payload shape. Before exposing the endpoint,
add: an ingest token or signed request check, a body-size cap, and rate limiting.
The store is write-only and forward-only; there is no read/delete path here.
