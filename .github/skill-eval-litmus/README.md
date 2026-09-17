# Litmus Skill Eval (CI)

Submits VSS skills to NVIDIA's hosted [Litmus](https://litmus.nvidia.com)
`skill-eval-agent` on every PR that touches `skills/**`, and posts a sticky
PR comment linking to each skill's report.

**This is a separate, independent signal from
[`skills-eval.yml`](../workflows/skills-eval.yml).** That pipeline is a
bespoke, self-hosted Harbor/Brev/claude-agent-sdk system built specifically
for VSS. This workflow instead calls Litmus's own hosted evaluator — one
HTTP call per changed skill, run entirely on Litmus's infrastructure. The
two pipelines don't share code, secrets, or gating and can be added,
changed, or removed independently.

Advisory only: a Litmus eval result never fails the build. Only submit
transport/auth/quota errors are even logged, as a `::warning` — see
[`submit_run.py`](submit_run.py).

## How it works

1. [`plan.py`](plan.py) diffs the PR (or, for a `workflow_dispatch` run with
   an explicit `skill_name`, skips diffing) and emits the set of changed
   skill names as a job matrix — one leg per skill, not per spec/platform
   (Litmus's API takes one `(skill_source, skill_name)` pair per call).
2. Each `litmus-eval` matrix leg resolves a `skill_source` — a GitHub
   `tree/<PR-head-SHA>/skills/<skill>` URL pinned to the commit under
   review (or the `workflow_dispatch` `skill_source` override) — and calls
   [`submit_run.py`](submit_run.py), which `POST`s
   `/api/v1/skill-eval-agent/requests` with `eval_type: hybrid` and writes
   its own `<skill>.json` result to an artifact. **It does not wait for the
   eval to finish** — Litmus evals take minutes to hours; submitting and
   moving on avoids holding a CI runner for that whole window.
3. The `report` job downloads every leg's result artifact and calls
   [`post_report_comment.py`](post_report_comment.py), which upserts one
   sticky PR comment (hidden marker `<!-- skills-eval-litmus-bot:v1 -->`,
   distinct from `skills-review.yml`'s own sticky comment) with a table of
   skill → run id → report URL.

## Required secrets

| Secret | Purpose |
|---|---|
| `LITMUS_API_TOKEN` | Bearer token (`litmus_pat_…`) from https://litmus.nvidia.com — scope it to the `skill-eval-agent` agent. Each token has a 50-submits/day quota. |
| `LITMUS_BASE_URL` | Litmus host, e.g. `https://litmus.nvidia.com` |

## Manual runs

`workflow_dispatch` accepts:

- `skill_name` — a bare skill-dir name (e.g. `vss-ask-video`). Bypasses the
  PR diff and dispatches exactly that one skill.
- `skill_source` — an explicit GitHub/GitLab URL to eval instead of the
  auto-derived `tree/<sha>/skills/<skill>` link. Required for private forks
  Litmus can't fetch, or to eval a ref other than the PR head.

## Local test

```bash
python3 -m pytest .github/skill-eval-litmus/tests/ -v
```
