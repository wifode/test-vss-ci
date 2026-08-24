# CI Override — Unattended FVR Execution

This file is injected ONLY for GitHub Actions runs of the VSS FVR pipeline,
via `--append-system-prompt` in `scripts/ci/run-vss-fvr.sh`. It is never
imported by `CLAUDE.md`/`AGENTS.md`, so interactive/local FVR sessions are
completely unaffected by anything below.

Follow the normal `AGENTS.md` pipeline exactly, with the following
overrides at the three points that normally block on a human. The guiding
rule across all three: **prefer a well-evidenced answer over failing, but
never fabricate one, and never let an unresolved question hang the run.**

## Step 0 — Test plan confirmation

- **If the run's log directory already contains a `00-config.yaml` with
  `status: confirmed`** (the CI driver copies a matched pre-baked plan in
  before invoking you): treat it exactly as AGENTS.md's Step 1 already
  instructs — reuse it as-is, do not invoke test-plan-creator, do not run
  the live confirmation gate. Still write a `00b-user-inputs.md` noting this
  run reused a pre-confirmed offline plan (its path, and its original
  `confirmed_at`/`confirmed_run`), so the run has the same audit trail an
  interactive gate would produce.
- **If the log directory has no config yet:** invoke test-plan-creator
  normally, exactly as an interactive run would, using the profile,
  detected hardware, and mode passed to you in the run prompt. When it
  returns its "TEST PLAN READY" summary block, do not wait for a human —
  immediately set `status: confirmed` plus `confirmed_at` (today's date) and
  `confirmed_run` (this run's log directory name) on the plan file yourself,
  and write `00b-user-inputs.md` recording: the summary block, the fact that
  confirmation was CI-automatic (not human), and a note that this plan is a
  candidate for promotion into `review-configs/` if a maintainer reviews and
  likes it. Then proceed to Step 1.
- **If test-plan-creator instead returns an OPEN QUESTIONS block with no
  plan:** see "Open questions with a likely answer" below before treating
  this as a failure.
- **If the specifically-requested `LLM_MODE`/`VLM_MODE` combination does
  not fit the *actual detected hardware* per the product's own documented
  sizing rules** (e.g. the docs say a 2-GPU host can't run this pairing
  locally, or that this profile needs a GPU count you don't have): **do
  not silently substitute a different mode and proceed.** The CI matrix
  intentionally includes combinations that may not fit every box it runs
  on -- the correct response to a genuine mismatch is to stop cleanly, not
  to quietly test a different configuration than the one the run was
  labeled with. Write `CI-SKIPPED-INFEASIBLE.md` to the log directory: one
  paragraph stating the requested combination, the detected hardware, and
  the specific documented rule that rules it out (cite the doc/section).
  Then stop -- do not invoke test-plan-creator further, do not proceed to
  Step 1. This is a correct, expected outcome for some matrix cells, not a
  failure.

## Step 1b — Feature clarifications

For any `features[].requires_clarification: true` entry:

1. First, try to answer it yourself from what the repo/docs already
   establish — check for existing example configs, sample data, or
   documented defaults relevant to the feature (e.g. `industry-profiles/*/`
   example configs, sample alert-type lists in the alerts docs, existing
   `.env` defaults). If you can identify a single reasonably likely choice
   this way, use it. Record the choice and your reasoning/evidence in
   `00b-user-inputs.md` as a CI-assumed answer, exactly like an "open
   questions with a likely answer" case below.
2. If no defensible single choice exists, answer `skip` — this is a normal,
   non-failure outcome AGENTS.md already supports, not a fallback of last
   resort to feel bad about. Record that the feature was skipped and why.
3. Never leave a feature clarification unanswered — pick (1) or (2), always.

## Open questions with a likely answer (applies anywhere in the pipeline)

Any subagent may surface a blocking question. Some of these come with the
subagent's own stated likely/suggested answer (e.g. test-plan-creator
inferring "this profile clearly needs `-H L40S --use-remote-llm` given the
detected hardware"). When a subagent states a single likely answer with
its own reasoning:

- **Accept it and continue** — do not stop the run to relay it to a human.
- Record the accepted suggestion **verbatim**, plus which subagent proposed
  it, in `00b-user-inputs.md` and again in the final report's notes, so a
  human reviewing the report later can see exactly what was assumed and
  override it if wrong.
- The bar for "accept" is the subagent's own confidence: only take this
  branch when it states a single likely answer, not when it lists multiple
  plausible options with no lean.

## Step 8 — Grounding verification

- Read `06-final-report.md` and `03-test-results.md` yourself, exactly as
  AGENTS.md's Step 8 describes.
- For every Top Issue, apply **KEEP** — never `REMOVE` and never silently
  edit a finding's substance. CI's job is to surface everything the run
  found; curation is a human's call, not this run's.
- Write `07-grounded-report.md` directly from this auto-applied decision.
  Do not modify the report title (still "{Product Name} Functional Virtual
  Review", no "(Grounded)"/"(CI)" suffix).
- Note explicitly in the report (e.g. in a closing notes section) that
  grounding was CI-auto-confirmed (`KEEP` applied to all issues) rather than
  human-reviewed, so a reader knows to apply their own judgment before
  treating every Top Issue as fully vetted.

## Report integrity — what the missing human gate used to catch

An unattended run has no human at Step 8 to say "you dropped three things
your own quality reviewer flagged." A side-by-side against a
human-grounded report of the same product found the CI report's *evidence*
was sound (citations checked out against `02-commands.jsonl`) but its
*self-limiting discipline* had slipped. Enforce these yourself, in the
`Agent` prompt you give report-generator AND as a check you personally run
on `06-final-report.md` before Step 8:

- **Scope Limits section is mandatory.** `05-quality-review.md` contains an
  untested / unaddressed in-scope items list. Every entry in it must appear
  in a "Scope Limits" (or equivalently-named) section of the final report —
  a gap the quality reviewer explicitly flagged, silently absent from the
  report, is the single worst failure mode here, because the report then
  reads as more complete than the run actually was. In a real run the
  quality reviewer called one dropped item "a plan commitment that was
  quietly dropped" and the report never mentioned it. If the quality review
  flagged N gaps, the report discloses N gaps.
- **Top Issues must be patterns (2+ independent examples), per AGENTS.md.**
  Before accepting the report, check each Top Issue: does it cite at least
  two *independent* examples? "One root cause, two visible symptoms" is one
  example, not two — a single bug with downstream effects is still a single
  bug. A genuinely important one-off belongs in the detailed findings, not
  the Top Issues list. If an issue can't meet the bar, send it back to
  report-generator to either merge it with a related finding into a real
  pattern or demote it.
- **Every skipped/blocked pipeline step must be disclosed in the report.**
  If agentic-readiness wrote a skip stub (upstream fetch failed), if
  ui-tester wrote BLOCKED, if any required row is omitted — say so
  explicitly in the report body, with the reason. Omitting the row *and*
  omitting any mention of why is how a reader concludes the step passed.
- **Rows rated on thin evidence must say so in the cell.** A Performance
  row backed by a single measurement is not the same as one backed by
  several across streaming/non-streaming paths; state the sample size in
  the SUMMARY cell rather than presenting n=1 as if it were characterized.
- **Competitive Positioning needs citations like any other row** — it is
  researched, not asserted. A cell with zero references isn't a finding.

## Fail-closed clause

Only when you reach a point with **no default, no repo/doc evidence, and no
subagent-stated likely answer** — a genuinely open, multi-way ambiguity with
no defensible single choice — should you stop and fail the run. When this
happens:

- Write `logs/.../CI-BLOCKED.md` stating exactly what's unresolved, what
  options were considered, and why none could be chosen with confidence.
- Exit with a clear non-zero-style failure signal in your final message so
  the CI driver script can mark the job failed and surface this file as the
  reason (do not attempt to guess further or retry the same question).
- This should be rare — pre-baked plans, the CI-assumed-answer path, and
  `skip` for feature clarifications are designed to cover the vast majority
  of cases. Treat this clause as the last resort, not the default.

## General

- Never wait on stdin. Never emit a message whose only purpose is to ask a
  human a question — every decision point above has an explicit resolution
  path (reuse, auto-confirm, evidence-based guess, `skip`, or fail-closed).
- Every auto-resolved decision must be traceable in `00b-user-inputs.md` and
  the final report — "auto-resolved" is not the same as "unrecorded."
- **Model access varies by CI key — don't assume, and don't downgrade
  needlessly.** Every subagent definition in this repo declares
  `model: opus` for interactive use. Let the first `Agent` call of the run
  use that declared default as-is (don't override it preemptively — some
  CI keys do have opus access, and downgrading a key that doesn't need it
  just throws away quality for no reason). If that call fails with a 403
  model-access error (`key not allowed to access model ... This key can
  only access models=[...]`), that error names what the key *can* access —
  retry the same subagent call once with the best model from that list
  (prefer the closest available tier to opus, e.g. `sonnet` before
  `haiku`), then **reuse that same working override for every subsequent
  `Agent` call in this run** so the failure only costs one wasted attempt
  total, not one per subagent. Record which model ended up in use (and
  whether it required a fallback) in `00b-user-inputs.md`, since a report
  produced on a downgraded model is worth knowing about later.
- **NEVER end your turn before the pipeline is finished.** This is the single
  most expensive mistake available to you here. You are running under
  `claude -p`: **ending your turn ends the run.** There is no next turn, no
  human to prompt you, nothing that wakes you back up. Two real cells were
  lost this way — the agent started a long deploy, wrote *"continuing to wait
  for the deploy to finish"*, and ended its turn. The process exited
  reporting success, having produced no report, after ~$25 of spend. Never
  emit a message whose meaning is "I am waiting" or "I'll continue once X
  completes" — there is no later. Either the work is done in this turn, or
  the run is over. Your turn ends exactly twice: after Step 9 completes, or
  when the fail-closed clause fires.
- **Never run a long-running command in the background either — and that
  includes `nohup`/detached shells.** A slow `docker pull`/deploy (20-60
  minutes is normal and expected) must be run as a blocking foreground
  command and waited on to completion. Backgrounding it and ending your turn
  is the failure above. If a command needs a long time, give it a long
  timeout and block — do not poll, do not defer, do not hand control back.
  This extends the subagent rule below to plain Bash calls, which is where it
  actually bit.
  **This rule also protects credentials.** A detached `nohup bash -c "..."`
  cannot inherit your shell's exported environment, so it tempts you into
  interpolating secrets *into the command string* — which puts them in that
  process's argv, readable by any local user via `ps aux`, and echoes them
  into this run's transcript. That exact chain happened in a real run and
  leaked an NGC key. A foreground command inherits the environment normally
  and needs no interpolation, so blocking is both the correct control flow
  and the safe one. Secrets go in the inherited environment or over stdin
  (`--password-stdin`); never inside a quoted command string.
- **Never invoke a subagent in the background/async mode when your next
  action depends on its result.** This matches AGENTS.md's own execution
  model ("wait for it to finish ... before starting the next"), but it's
  load-bearing here for a reason specific to this headless invocation: this
  session has no interactive UI to deliver a background task's completion
  notification. The `claude -p` process running you has a fixed ceiling
  (minutes, not hours) on how long it will keep the process alive waiting
  for outstanding background work before force-terminating everything,
  including any deployed containers' state and whatever you were doing at
  the time — mid-run, not at a clean stopping point. Every fvr/perf/quality/
  report/agentic-readiness/ui subagent call in this pipeline gates the next
  step, so every one of them must be invoked and awaited synchronously,
  never backgrounded "to check back on later."
- **Never write a subagent's own designated output file yourself while
  that subagent is still running (or that you're claiming to be waiting
  on).** A real run produced a race: the orchestrator said it would wait for
  report-generator to finish `06-final-report.md`, then wrote that exact
  file itself in the same turn. Two writers on one canonical artifact risks
  a stale/partial version winning. If a subagent is genuinely stuck and you
  need to take over, stop it explicitly first (or wait for its actual
  completion signal), never write over/alongside it while it may still be
  running.
- **Pass a short standing-context block into every subagent's `Agent` call
  prompt** (fvr-tester, doc-reviewer, perf-tester, agentic-readiness,
  ui-tester, quality-reviewer, report-generator) — these are things a real
  run rediscovered the hard way, per subagent, at real time/token cost, and
  there's no reason for that to repeat:
  - "Every Bash call touching `${SERVER_HOST}` needs
    `dangerouslyDisableSandbox: true` — this is expected and known upfront
    for this fixed CI target, not something to discover via a failed
    retry."
  - "`ssh host \"export VAR=$LOCAL_VAR && ...\"` does NOT pass `VAR`
    through — `$LOCAL_VAR` is expanded by the *local* shell before the
    string is even sent. Pipe secrets over stdin (same pattern as
    `docker login --password-stdin`); for non-secret values, resolve them
    locally and interpolate the already-resolved literal."
  - "Write your output file incrementally as you go (after each phase,
    each finding, each target), not only in one Write call at the very
    end. This run can be interrupted (environment error, context limit)
    with no warning; an incremental file preserves your synthesis up to
    that point, a batch-at-the-end file loses all of it even though the
    raw command receipts in `02-commands.jsonl` survive independently."
  - (doc-reviewer only) "WebFetch enforces a ~125-character verbatim-quote
    limit — a single 'extract every code snippet verbatim from this whole
    page' request reliably trips it and silently falls back to a
    paraphrase. Request snippets in smaller per-section chunks instead, or
    fetch a raw markdown/source variant of the page if the docs site
    publishes one."
- **Don't make doc-reviewer re-fetch pages test-plan-creator already
  fetched.** In a real run, test-plan-creator fetched and extracted several
  doc pages while building the plan (its "Based on" section in
  `00-config.yaml` lists exactly which URLs it already pulled), then
  doc-reviewer re-fetched the identical URLs from scratch in Step 3 — pure
  duplicated WebFetch cost for content already sitting on disk. Before
  writing doc-reviewer's prompt, check `00-config.yaml`'s sourcing notes for
  pages test-plan-creator already fetched, and tell doc-reviewer to treat
  those as a verified starting point (skim the plan's own extraction, spot-
  check rather than blindly re-extracting) — it should only do a full fresh
  fetch for pages Step 0 didn't already cover.
