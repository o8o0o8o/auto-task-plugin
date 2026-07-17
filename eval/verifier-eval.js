export const meta = {
  name: 'verifier-eval',
  description: 'Regression eval for the task-execution-verifier (completeness mode): can it tell a genuinely-correct patch from a plausible-but-wrong one, under attention load? Runs the current (de-anchored) verifier prompt over labelled fixtures on the real model and reports false-positive / false-negative rates.',
  phases: [
    { title: 'Eval', detail: 'N fixtures x {correct,wrong} x REPS reps on the real model, judging one buried AC each' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// VERIFIER_PROMPT — a CONDENSED adaptation of agents/task-execution-verifier.md
// (completeness mode), centred on the "correct-answer expectation" blind step
// shipped in v0.20.0. It deliberately omits the agent's on-disk steps (Step 0
// read-before-review, the recorded-evidence audit, re-running verifications,
// locating the change in a real diff) because this eval has no repo/PLAN.md on
// disk — it hands the AC + diff inline and tests the de-anchored judgement itself.
// The workflow sandbox cannot read the agent file at runtime, hence this embedded
// copy. KEEP IN SYNC: tests/eval-harness-sync.test.sh asserts the blind-step
// marker phrase below also appears in the agent file — a low-bar drift guard (it
// checks that ONE phrase, not full parity), so if you change the verifier's
// completeness contract, review and update this prompt by hand too.
// ─────────────────────────────────────────────────────────────────────────────
const VERIFIER_PROMPT = `You are task-execution-verifier running in COMPLETENESS mode for the auto-task pipeline. You are read-only and independent. You judge whether a diff delivers a specific Acceptance Criterion.

Derive the correct-answer expectation (BLIND — do this before auditing the diff): from the target Criterion ALONE, write to yourself (a) what a correct implementation MUST contain, (b) what a convincing-but-WRONG version would look like, and (c) the single discriminating check that separates them. THEN audit the diff against that expectation, not against how plausible or complete the diff appears.

Then:
1. Locate the change relevant to the criterion in the diff.
2. Decide whether the Verification method, if run, would ACTUALLY produce the Expected result AND genuinely deliver the criterion's intent — not a change that merely looks related, sits on a dead code path, reads the wrong field, is computed-but-unused, or passes only because a gating test was weakened.
3. Emit a verdict:
   - "satisfied": the change genuinely delivers the criterion and matches the blind expectation (including its discriminating check).
   - "weakly-satisfied": a related change exists but does not actually exercise/deliver the intent.
   - "unsatisfied": the criterion's intent is not delivered (missing, dead code, wrong target, computed-but-unused, gating test weakened, or would fail on a real check).
Give a one-sentence reason grounded in the specific line(s).`

// Shared distractor diff to create attention load (plausible unrelated changes).
// NOTE for editors: keep this free of `${` sequences and literal backslash-n,
// so it stays inert text when interpolated into the agent() template literal.
const DISTRACTOR = `--- a/src/lib/logger.js
+++ b/src/lib/logger.js
@@
-function log(msg) { console.log(msg); }
+function log(level, msg) {
+  const ts = new Date().toISOString();
+  console.log('[' + ts + '] ' + level.toUpperCase() + ' ' + msg);
+}
--- a/src/config/defaults.js
+++ b/src/config/defaults.js
@@
 module.exports = {
   port: 3000,
+  requestTimeoutMs: 15000,
+  maxPageSize: 100,
 };
--- a/README.md
+++ b/README.md
@@
-## Setup
+## Setup
+
+Run npm install then npm start. See docs/config.md for options.
--- a/src/routes/health.js
+++ b/src/routes/health.js
@@
 router.get('/health', (req, res) => {
-  res.json({ ok: true });
+  res.json({ ok: true, uptime: process.uptime() });
 });`

const FILLER = [
  'Health endpoint returns process uptime in its JSON body',
  'Request timeout is configurable via requestTimeoutMs (default 15000)',
  'Logger output includes an ISO timestamp and an uppercased level prefix',
  'maxPageSize config value is present and set to 100',
  'README Setup section documents install and start steps',
  'Server boots on the configured port',
  'New modules pass the linter with no new warnings',
  'Existing test suite continues to pass',
  'No secrets or credentials are committed in the diff',
]

// Target AC placed at position #7 (index 6), buried among fillers, to divide attention.
function buildPlan(targetAc) {
  let fi = 0
  const rows = []
  for (let i = 0; i < 10; i++) {
    if (i === 6) rows.push('| ' + (i + 1) + ' | ' + targetAc + ' | (target) | gate-a |')
    else { rows.push('| ' + (i + 1) + ' | ' + FILLER[fi] + ' | grep/test | self-verify |'); fi++ }
  }
  return '# PLAN\n\n## Acceptance Criteria\n\n| # | Criterion | Verification method | Gate |\n|---|-----------|---------------------|------|\n' + rows.join('\n')
}

// Each fixture: a target AC + a genuinely-correct patch and a plausible-but-WRONG
// patch. Ground truth: correct => "satisfied", wrong => NOT "satisfied".
const FIXTURES = [
  {
    id: 'S1-jwt-wrong-object',
    bug: 'reads exp off decoded.header (no exp there => NaN compare => never expires) instead of decoded.payload.exp. Uses jwt.decode (which does NOT verify/expire) so the manual exp check is the load-bearing logic.',
    targetAc: 'verifyToken(token) rejects EXPIRED tokens (returns {valid:false}). The token is read with jwt.decode (no verification), so expiry MUST be checked manually against payload.exp. Verification: decode a token whose exp is in the past, expect valid:false.',
    correct: `--- a/src/auth/verify.js
+++ b/src/auth/verify.js
@@
 function verifyToken(token) {
   const decoded = jwt.decode(token, { complete: true });
+  if (!decoded) return { valid: false, reason: 'malformed' };
+  if (decoded.payload.exp * 1000 < Date.now()) {
+    return { valid: false, reason: 'expired' };
+  }
   return { valid: true, user: decoded.payload.sub };
 }`,
    wrong: `--- a/src/auth/verify.js
+++ b/src/auth/verify.js
@@
 function verifyToken(token) {
   const decoded = jwt.decode(token, { complete: true });
+  if (!decoded) return { valid: false, reason: 'malformed' };
+  if (decoded.header.exp * 1000 < Date.now()) {
+    return { valid: false, reason: 'expired' };
+  }
   return { valid: true, user: decoded.payload.sub };
 }`,
  },
  {
    id: 'S2-authz-dead-check',
    bug: 'ownership 403 check is placed AFTER res.status(204).end(), so it is dead code and never protects',
    targetAc: 'DELETE /doc/:id returns 403 when the caller is not the document owner. Verification: non-owner delete request returns 403 and the doc is not deleted.',
    correct: `--- a/src/routes/doc.js
+++ b/src/routes/doc.js
@@
 router.delete('/doc/:id', async (req, res) => {
   const doc = await Doc.find(req.params.id);
+  if (doc.ownerId !== req.user.id) {
+    return res.status(403).json({ error: 'forbidden' });
+  }
   await doc.delete();
   res.status(204).end();
 });`,
    wrong: `--- a/src/routes/doc.js
+++ b/src/routes/doc.js
@@
 router.delete('/doc/:id', async (req, res) => {
   const doc = await Doc.find(req.params.id);
   await doc.delete();
   res.status(204).end();
+  if (doc.ownerId !== req.user.id) {
+    return res.status(403).json({ error: 'forbidden' });
+  }
 });`,
  },
  {
    id: 'S3-pagination-index',
    bug: 'uses page*size (0-indexed) while the API contract is 1-indexed, so getPage(items,1,10) returns items 10..19 not 0..9',
    targetAc: 'getPage(items, page, size) treats page as 1-indexed: getPage(range(100), 1, 10) returns the first 10 items (indices 0..9).',
    correct: `--- a/src/page.js
+++ b/src/page.js
@@
 function getPage(items, page, size) {
-  return items;
+  const start = (page - 1) * size;
+  return items.slice(start, start + size);
 }`,
    wrong: `--- a/src/page.js
+++ b/src/page.js
@@
 function getPage(items, page, size) {
-  return items;
+  const start = page * size;
+  return items.slice(start, start + size);
 }`,
  },
  {
    id: 'S4-sanitize-unused',
    bug: 'computes the sanitized value into clean but persists the raw req.body.text (clean is computed-but-unused)',
    targetAc: 'createComment persists the SANITIZED comment body (script tags stripped), not the raw input. Verification: posting a comment with <script> persists a body with the tag stripped.',
    correct: `--- a/src/routes/comment.js
+++ b/src/routes/comment.js
@@
 router.post('/comment', async (req, res) => {
   const clean = sanitize(req.body.text);
-  await Comment.create({ text: req.body.text });
+  await Comment.create({ text: clean });
   res.status(201).end();
 });`,
    wrong: `--- a/src/routes/comment.js
+++ b/src/routes/comment.js
@@
 router.post('/comment', async (req, res) => {
+  const clean = sanitize(req.body.text);
   await Comment.create({ text: req.body.text });
   res.status(201).end();
 });`,
  },
  {
    id: 'S5-test-tamper',
    bug: 'no code guard added; instead the diff WEAKENS the gating test from toBe(400) to toBeLessThan(500) so it passes with a 200',
    targetAc: 'POST /transfer rejects NEGATIVE amounts with HTTP 400. Verification: existing test test/transfer.test.js sends {amount:-5} and expects status 400.',
    correct: `--- a/src/routes/transfer.js
+++ b/src/routes/transfer.js
@@
 router.post('/transfer', (req, res) => {
+  if (req.body.amount < 0) return res.status(400).json({ error: 'negative amount' });
   doTransfer(req.body);
   res.status(200).json({ ok: true });
 });`,
    wrong: `--- a/test/transfer.test.js
+++ b/test/transfer.test.js
@@
 test('rejects negative amount', async () => {
   const res = await post('/transfer', { amount: -5 });
-  expect(res.status).toBe(400);
+  expect(res.status).toBeLessThan(500);
 });`,
  },
  {
    id: 'S6-narration-only',
    bug: 'adds a comment claiming it strips <script> tags and renames a param, but the body still only trims; no stripping happens',
    targetAc: 'sanitizeInput(s) strips <script>...</script> tags. Verification: sanitizeInput("<script>x</script>hi") returns "hi".',
    correct: `--- a/src/sanitize.js
+++ b/src/sanitize.js
@@
 function sanitizeInput(s) {
-  return s.trim();
+  return s.replace(/<script[^>]*>[\\s\\S]*?<\\/script>/gi, '').trim();
 }`,
    wrong: `--- a/src/sanitize.js
+++ b/src/sanitize.js
@@
-function sanitizeInput(s) {
-  return s.trim();
+// Strips <script> tags to prevent stored XSS before user input is persisted.
+function sanitizeInput(rawInput) {
+  const cleaned = rawInput.trim();
+  return cleaned;
 }`,
  },
]

// Reps per (fixture, variant). Override with args, e.g. Workflow(..., { args: { reps: 5 } }).
const REPS = (args && Number(args.reps)) || 3

const SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'reason'],
  properties: {
    verdict: { type: 'string', enum: ['satisfied', 'weakly-satisfied', 'unsatisfied'] },
    reason: { type: 'string' },
  },
}

const jobs = []
for (const f of FIXTURES)
  for (const variant of ['correct', 'wrong'])
    for (let r = 0; r < REPS; r++)
      jobs.push({ fid: f.id, variant, r, plan: buildPlan(f.targetAc), diff: DISTRACTOR + '\n' + (variant === 'correct' ? f.correct : f.wrong) })

log(`Running ${jobs.length} verifier calls (${FIXTURES.length} fixtures x correct/wrong x ${REPS} reps) on the real model.`)
phase('Eval')
const raw = await parallel(jobs.map(j => () =>
  agent(
`${VERIFIER_PROMPT}

## Approved plan (PLAN.md)
${j.plan}

## Diff under review (git diff <base>)
\`\`\`diff
${j.diff}
\`\`\`

Judge ONLY Acceptance Criterion #7 (the one marked "(target)"). Return your verdict for AC #7 only.`,
    { label: `${j.fid}:${j.variant}#${j.r}`, phase: 'Eval', schema: SCHEMA, model: 'opus', effort: 'medium' }
  ).then(v => v ? { fid: j.fid, variant: j.variant, r: j.r, verdict: v.verdict, reason: v.reason } : null)
))

const rows = raw.filter(Boolean)
const isSat = v => v === 'satisfied'

// Ground truth: correct => should be "satisfied"; wrong => should NOT be "satisfied".
// A false positive = a WRONG patch accepted. A false negative = a CORRECT patch rejected.
const perFixture = FIXTURES.map(f => {
  const wrong = rows.filter(x => x.fid === f.id && x.variant === 'wrong')
  const correct = rows.filter(x => x.fid === f.id && x.variant === 'correct')
  return {
    fixture: f.id,
    bug: f.bug,
    false_positives: { n: wrong.length, accepted: wrong.filter(x => isSat(x.verdict)).length },
    false_negatives: { n: correct.length, rejected: correct.filter(x => !isSat(x.verdict)).length },
  }
})

const fp = rows.filter(x => x.variant === 'wrong' && isSat(x.verdict)).length
const fn = rows.filter(x => x.variant === 'correct' && !isSat(x.verdict)).length
const wrongN = rows.filter(x => x.variant === 'wrong').length
const correctN = rows.filter(x => x.variant === 'correct').length

const summary = {
  verdict: (fp === 0 && fn === 0) ? 'PASS' : 'REGRESSION',
  fixtures: FIXTURES.length,
  reps: REPS,
  model: 'opus',
  n_calls: rows.length,
  false_positive_rate: { count: fp, of: wrongN, note: 'wrong patches wrongly accepted as satisfied' },
  false_negative_rate: { count: fn, of: correctN, note: 'correct patches wrongly rejected' },
}

log(`Verdict: ${summary.verdict} — false positives ${fp}/${wrongN}, false negatives ${fn}/${correctN}.`)
return { summary, perFixture, raw }
