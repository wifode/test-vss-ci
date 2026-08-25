#!/usr/bin/env bash
# Unattended, per-profile VSS FVR driver for CI.
# See ~/.claude/plans/i-need-a-script-majestic-perlis.md (Part 4) for the
# design this implements. Never prompts; always terminates (timeout-bounded).
#
# Usage:
#   scripts/ci/run-vss-fvr.sh <profile> [--llm-mode M] [--vlm-mode M] \
#       [--llm-provider P] [--vlm-provider P] [--timeout-hours N] \
#       [--docs-url URL [--docs-url URL ...]]
#
# Documentation URLs, in precedence order:
#   1. --docs-url URL   (repeatable CLI flag, wins over everything)
#   2. $FVR_DOCS_URLS   (comma-separated -- the form CI systems can carry in
#                        a single env/variable field; whitespace tolerated)
#   3. built-in VSS quickstart + prerequisites defaults
# Point these at a pinned docs version, a staging mirror, or a different
# starting page without editing this script. Pinning is worth considering for
# a long matrix run: several cells crawling `/latest/` over many hours can
# silently read different source material if the docs update mid-run.
#
# --stop-after <preflight|plan|deploy|test>  TESTING/DEV ONLY. Stops the
#   pipeline early so a change to this script or ci/CI_OVERRIDE.md can be
#   validated in minutes for cents instead of a full multi-hour run. The
#   resulting artifacts are partial by design and CI-STATUS says so; never
#   publish or promote them. `preflight` never even invokes the agent.
#
# --resume <log-dir>  Re-enter an interrupted run at the first step whose
#   output artifact is missing, reusing that directory instead of creating a
#   new one. For finishing THIS run only -- never point it at an older run's
#   directory (see AGENTS.md's clean-run rules).
#
# Product-agnostic knobs (this driver is not VSS-specific beyond its
# defaults -- set these to point it at any product on any SSH box):
#   FVR_PRODUCT_SLUG     log-directory name prefix (default "vss")
#   FVR_LOGS_ROOT        root of the default log-dir layout (default:
#                        $FVR_SKILL_REPO/logs) -- point outside the fvr-skill
#                        checkout on a runner that wipes/re-clones it every
#                        run, so history survives across runs
#   REMOTE_VSS_REPO_DIR  checkout path on the remote box
#   REMOTE_TEARDOWN_CMD  teardown command run from that directory
#   FVR_ENFORCE_REPORT_INTEGRITY  "true" makes the post-report integrity
#                        check fail the run instead of warning (default off)
#
# Required env vars (see scripts/ci/vss-preflight.py for the authoritative,
# profile/mode-conditional required set):
#   SERVER_HOST, SERVER_USER, SSH_KEY_PATH, ANTHROPIC_API_KEY
#   NGC_API_KEY / NVIDIA_API_KEY / OPENAI_API_KEY / HF_TOKEN as applicable
#   LLM_ENDPOINT_URL, NV_API_KEY when the selected mode is remote
#
# If ANTHROPIC_API_KEY is an NVIDIA inference-hub key (not a direct
# api.anthropic.com key), it must be paired with ANTHROPIC_BASE_URL (e.g.
# https://inference-api.nvidia.com) and ANTHROPIC_MODEL (the model ID your
# route expects) -- claude inherits these from the environment as-is, no
# script change needed. Without ANTHROPIC_BASE_URL, an NVIDIA-hub key gets
# sent to api.anthropic.com directly and fails with a 401.
#
# TROUBLESHOOTING ONLY -- do not set this by default, it has a real
# reasoning-quality cost: if the run fails with an HTTP 400 mentioning
# `context_management`, your NVIDIA proxy may be rejecting that field (VSS's
# own CI infra hit this on their proxy/CLI-version combo). The only known
# workaround is CLAUDE_CODE_DISABLE_THINKING=1, which disables extended
# thinking entirely to stop the field from being sent -- try WITHOUT it
# first; only add it if you actually reproduce this specific error. See
# AI_ASSETS/DECISIONS.md D18.
#
# Env vars this script reads for CI plumbing only (not product credentials):
#   FVR_SKILL_REPO   (default: repo root two levels up from this script)
#   VSS_REPO_LOCAL_REFERENCE  (default: sibling checkout ../video-search-and-summarization)
#   REMOTE_VSS_REPO_DIR       (default: ~/video-search-and-summarization on SERVER_HOST)
#   GDOC_ENABLED, LITMUS_ENABLED  ("true"/"false", default "false")
#
# IMPORTANT: VSS_REPO_LOCAL_REFERENCE is a checkout on whatever machine runs
# THIS script (e.g. the CI runner) -- used ONLY by vss-preflight.py to read
# each profile's .env template (for the required-var check) and by
# test-plan-creator to read skill reference docs when no pre-baked plan
# matches. This script does NOT clone, copy, or install VSS onto the SSH
# target (SERVER_HOST) at any point. Getting VSS onto the remote GPU box is
# the agent's own Doc-Faithful Testing responsibility (AGENTS.md Design
# Principle #1) -- it follows the product's published docs live over SSH,
# the same way a real developer would, including testing the documented
# git-clone/git-lfs steps themselves. See AI_ASSETS/DECISIONS.md ("No pre-install
# of VSS onto the remote box") for why.

set -uo pipefail

# Local-machine-only guard: on macOS, an unattended run left on a laptop can
# get killed mid-stream by system idle sleep -- this actually happened
# (AI_ASSETS/DECISIONS.md I16): the local machine slept 3x during a ~2h run,
# fatally cutting off the final Step 8 grounding write (no retry logic at
# that orchestrator-only step) and separately breaking the driver's own
# teardown SSH connection for ~2.5h before it happened to recover. A real
# GitHub Actions runner never sleeps, so this re-exec is a no-op there
# (no `caffeinate` binary) -- it exists purely for local/manual testing on a
# laptop. `caffeinate -i` prevents idle sleep for exactly the lifetime of the
# wrapped process tree, nothing more persistent or system-wide.
if [[ "$(uname -s)" == "Darwin" ]] && command -v caffeinate >/dev/null 2>&1 && [[ -z "${_VSS_FVR_CAFFEINATED:-}" ]]; then
  export _VSS_FVR_CAFFEINATED=1
  exec caffeinate -i "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FVR_SKILL_REPO="${FVR_SKILL_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
VSS_REPO_LOCAL_REFERENCE="${VSS_REPO_LOCAL_REFERENCE:-$(cd "$FVR_SKILL_REPO/.." 2>/dev/null && pwd)/video-search-and-summarization}"

PROFILE="${1:?usage: run-vss-fvr.sh <profile> [options]}"
shift || true

LLM_MODE="remote"
VLM_MODE="local"
LLM_PROVIDER="nvidia"
VLM_PROVIDER=""
TIMEOUT_HOURS="3"
DOCS_URLS=()
STOP_AFTER=""
RESUME_DIR=""
LOG_DIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --llm-mode) LLM_MODE="$2"; shift 2 ;;
    --vlm-mode) VLM_MODE="$2"; shift 2 ;;
    --llm-provider) LLM_PROVIDER="$2"; shift 2 ;;
    --vlm-provider) VLM_PROVIDER="$2"; shift 2 ;;
    --timeout-hours) TIMEOUT_HOURS="$2"; shift 2 ;;
    # Repeatable: --docs-url <url> [--docs-url <url> ...]. This script used to
    # hardcode VSS's quickstart/prerequisites URLs directly into the agent
    # prompt -- that made the driver silently VSS-specific in a way that
    # wasn't obvious from its interface, and gave the caller no way to point
    # a run at a different doc set (a docs revision, a staging mirror, or a
    # different starting page) without editing the script. Falls back to the
    # VSS defaults below only if the caller never passes any.
    --docs-url) DOCS_URLS+=("$2"); shift 2 ;;
    # TESTING/DEV ONLY -- never for a real review. Stops the pipeline early so
    # a driver-script or CI_OVERRIDE.md change can be validated in minutes for
    # cents instead of a full ~2h/$30 run. A run stopped early is deliberately
    # NOT a review: it produces partial artifacts, no report, and is marked as
    # such in CI-STATUS so it can never be mistaken for a real result.
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    # Resume an interrupted run in an EXISTING log directory instead of
    # creating a new one. Re-enters at the first step whose output artifact is
    # missing. Only ever valid for resuming *this same run* -- see the
    # clean-run rules in AGENTS.md; never point it at an older run's directory
    # to "top it up".
    --resume) RESUME_DIR="$2"; shift 2 ;;
    # Use exactly this directory instead of deriving logs/<slug>-<profile>-<date>[-runN].
    # Lets a caller that owns the layout (run-fvr-matrix.sh groups cells under
    # one parent run directory) place this run's artifacts precisely, without
    # the per-run collision rule scattering sibling cells across the logs/ root.
    --log-dir) LOG_DIR_OVERRIDE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$RESUME_DIR" && -n "$LOG_DIR_OVERRIDE" ]]; then
  echo "FATAL: --resume and --log-dir are mutually exclusive (both choose the" >&2
  echo "run's directory). Use --resume alone to continue an existing run." >&2
  exit 2
fi

case "$STOP_AFTER" in
  ""|preflight|plan|deploy|test) ;;
  *) echo "FATAL: --stop-after must be one of: preflight, plan, deploy, test" >&2; exit 2 ;;
esac

if [[ -n "$STOP_AFTER" ]]; then
  echo "[run-vss-fvr] ############################################################" >&2
  echo "[run-vss-fvr] TESTING MODE: --stop-after=$STOP_AFTER" >&2
  echo "[run-vss-fvr] This run will STOP EARLY and produce NO usable review." >&2
  echo "[run-vss-fvr] Its artifacts are partial by design. Never publish them," >&2
  echo "[run-vss-fvr] never promote its plan to review-configs/, never treat" >&2
  echo "[run-vss-fvr] its output as a real FVR result." >&2
  echo "[run-vss-fvr] ############################################################" >&2
fi

if [[ -n "$RESUME_DIR" && -n "$STOP_AFTER" ]]; then
  echo "FATAL: --resume and --stop-after are mutually exclusive." >&2
  exit 2
fi
if [[ -n "$RESUME_DIR" && ! -d "$RESUME_DIR" ]]; then
  echo "FATAL: --resume directory does not exist: $RESUME_DIR" >&2
  exit 2
fi

# Doc-URL precedence: --docs-url flags > $FVR_DOCS_URLS > built-in default.
# The env var is comma-separated because that's the shape CI systems can
# actually carry -- a GitHub Actions `env:` value or repo variable is a single
# string field, so a repeatable CLI flag has no equivalent there. Whitespace
# around entries is tolerated (a human-edited list usually has it) and empty
# entries are dropped, so a stray trailing comma isn't an error.
if [[ ${#DOCS_URLS[@]} -eq 0 && -n "${FVR_DOCS_URLS:-}" ]]; then
  IFS=',' read -ra _raw_docs_urls <<< "$FVR_DOCS_URLS"
  for _u in "${_raw_docs_urls[@]}"; do
    _u="${_u#"${_u%%[![:space:]]*}"}"   # trim leading whitespace
    _u="${_u%"${_u##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -n "$_u" ]] && DOCS_URLS+=("$_u")
  done
  if [[ ${#DOCS_URLS[@]} -gt 0 ]]; then
    echo "[run-vss-fvr] Using \$FVR_DOCS_URLS:" >&2
    printf '  %s\n' "${DOCS_URLS[@]}" >&2
  else
    echo "[run-vss-fvr] WARNING: FVR_DOCS_URLS was set but parsed to no usable" >&2
    echo "URLs -- falling back to the built-in defaults below." >&2
  fi
fi

if [[ ${#DOCS_URLS[@]} -eq 0 ]]; then
  DOCS_URLS=(
    "https://docs.nvidia.com/vss/latest/quickstart.html"
    "https://docs.nvidia.com/vss/latest/prerequisites.html"
  )
  echo "[run-vss-fvr] No --docs-url or \$FVR_DOCS_URLS given -- defaulting to VSS's published docs:" >&2
  printf '  %s\n' "${DOCS_URLS[@]}" >&2
fi
DOCS_URLS_TEXT="$(printf '%s\n' "${DOCS_URLS[@]}")"

GDOC_ENABLED="${GDOC_ENABLED:-false}"
LITMUS_ENABLED="${LITMUS_ENABLED:-false}"

if [[ ! -d "$VSS_REPO_LOCAL_REFERENCE" ]]; then
  echo "FATAL: no local VSS reference checkout at $VSS_REPO_LOCAL_REFERENCE" >&2
  echo "(set VSS_REPO_LOCAL_REFERENCE to override -- this is a local copy for" >&2
  echo "this script's own tooling only; see the header comment above)." >&2
  exit 1
fi

# --- Step 1: preflight (env vars + SSH/GPU + plan match) -------------------
# Build a JSON blob of the CI env vars the preflight script needs to check,
# written to a private temp file so no secret value ever appears on the
# command line or in shell history.
ENV_JSON_TMP="$(mktemp)"
trap 'rm -f "$ENV_JSON_TMP"' EXIT

python3 - "$ENV_JSON_TMP" <<'PY'
import json, os, sys
names = [
    "NGC_CLI_API_KEY", "NGC_API_KEY", "NVIDIA_API_KEY", "OPENAI_API_KEY",
    "HF_TOKEN", "ANTHROPIC_API_KEY", "GDRIVE_ACCESS_TOKEN", "LITMUS_BASE_URL",
]
# NGC_API_KEY (the FVR-wide var name) satisfies NGC_CLI_API_KEY's requirement
# too, matching setup.env_vars in the pre-baked plan.
env = {n: os.environ.get(n, "") for n in names}
if not env.get("NGC_CLI_API_KEY") and env.get("NGC_API_KEY"):
    env["NGC_CLI_API_KEY"] = env["NGC_API_KEY"]
with open(sys.argv[1], "w") as f:
    json.dump(env, f)
PY

echo "[run-vss-fvr] Running preflight for profile=$PROFILE llm_mode=$LLM_MODE vlm_mode=$VLM_MODE ..."
PREFLIGHT_OUT="$(mktemp)"
python3 "$SCRIPT_DIR/vss-preflight.py" \
  --profile "$PROFILE" \
  --vss-repo "$VSS_REPO_LOCAL_REFERENCE" \
  --review-configs-dir "$FVR_SKILL_REPO/review-configs" \
  --llm-mode "$LLM_MODE" --vlm-mode "$VLM_MODE" \
  --llm-provider "$LLM_PROVIDER" --vlm-provider "$VLM_PROVIDER" \
  --server-host "${SERVER_HOST:-}" --server-user "${SERVER_USER:-}" \
  --ssh-key-path "${SSH_KEY_PATH:-}" \
  --env-json "$ENV_JSON_TMP" \
  $( [[ "$GDOC_ENABLED" == "true" ]] && echo --gdoc-enabled ) \
  $( [[ "$LITMUS_ENABLED" == "true" ]] && echo --litmus-enabled ) \
  > "$PREFLIGHT_OUT" 2>&1
PREFLIGHT_STATUS=$?
rm -f "$ENV_JSON_TMP"
trap - EXIT

if [[ $PREFLIGHT_STATUS -ne 0 ]]; then
  echo "[run-vss-fvr] PREFLIGHT FAILED. This is a hard stop -- nothing" >&2
  echo "downstream can fix a preflight failure, so it's not retried." >&2
  echo "" >&2
  echo "--- actual error from vss-preflight.py (exit $PREFLIGHT_STATUS) ---" >&2
  cat "$PREFLIGHT_OUT" >&2
  echo "--- end preflight output ---" >&2
  echo "" >&2
  echo "[run-vss-fvr] Preflight fails on missing/invalid credentials, SSH" >&2
  echo "unreachability, no GPUs reported, or a missing profile .env -- see the" >&2
  echo "error above for which one this actually was." >&2
  rm -f "$PREFLIGHT_OUT"
  exit 1
fi

MATCHED_PLAN="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('matched_plan') or '')" "$PREFLIGHT_OUT")"
DETECTED_GPUS="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(', '.join(g['name'] for g in d['detected_gpus']))" "$PREFLIGHT_OUT")"
echo "[run-vss-fvr] Preflight OK. Detected GPUs: $DETECTED_GPUS"
rm -f "$PREFLIGHT_OUT"

# T0 for timing: the moment we've actually SSH'd into the box and confirmed
# its GPUs (preflight just did exactly that). This is the "SSH-in" reference
# point for the SSH-to-report-generation metric the run records at the end.
T_SSH_VERIFIED="$(date -u +%s)"

# --- Step 2: log directory + plan placement ---------------------------------
# FVR_PRODUCT_SLUG keeps the log-dir naming from being hardwired to one
# product -- the pipeline itself is product-agnostic, only this label isn't.
FVR_PRODUCT_SLUG="${FVR_PRODUCT_SLUG:-vss}"
if [[ -n "$RESUME_DIR" ]]; then
  # Resume reuses the directory as-is. Deliberately does NOT apply the
  # -runN collision rule: the whole point is to re-enter the SAME run's
  # directory and finish it, not to start a sibling run beside it.
  LOG_DIR="$(cd "$RESUME_DIR" && pwd)"
  echo "[run-vss-fvr] RESUMING into existing log directory: $LOG_DIR"
elif [[ -n "$LOG_DIR_OVERRIDE" ]]; then
  # Caller owns the layout; no -runN rule here. Collision-avoidance is the
  # caller's job (the matrix runner applies it to the PARENT run directory,
  # so cells stay grouped under one run instead of scattering).
  LOG_DIR="$LOG_DIR_OVERRIDE"
  mkdir -p "$LOG_DIR"
  echo "[run-vss-fvr] Log directory (caller-specified): $LOG_DIR"
else
  # Root of the default (date+profile, -runN-deduped) log directory layout.
  # Defaults to inside the fvr-skill checkout (unchanged local/non-CI
  # behavior); on a self-hosted runner where fvr-skill/ gets wiped and
  # re-cloned every run (the checkout is ephemeral input, not durable
  # storage), point this at a location outside that checkout instead so run
  # history actually survives across runs -- otherwise every run's logs are
  # deleted by the next run's checkout before anyone can look at them.
  FVR_LOGS_ROOT="${FVR_LOGS_ROOT:-$FVR_SKILL_REPO/logs}"
  DATE_STR="$(date -u +%Y-%m-%d)"
  BASE_DIR_NAME="${FVR_PRODUCT_SLUG}-${PROFILE}-${DATE_STR}"
  LOG_DIR="$FVR_LOGS_ROOT/${BASE_DIR_NAME}"
  RUN_N=2
  while [[ -d "$LOG_DIR" ]]; do
    LOG_DIR="$FVR_LOGS_ROOT/${BASE_DIR_NAME}-run${RUN_N}"
    RUN_N=$((RUN_N + 1))
  done
  mkdir -p "$LOG_DIR"
  echo "[run-vss-fvr] Log directory: $LOG_DIR"
fi

# --- Resume: find the first pipeline step whose artifact is missing ---------
# Artifact -> the step that produces it, in pipeline order. Resume re-enters
# at the first gap rather than trusting a recorded status, because the files
# on disk are the only thing that actually proves a step finished (a run can
# die mid-write, and CI-STATUS may never have been written at all).
RESUME_CONTEXT=""
if [[ -n "$RESUME_DIR" ]]; then
  RESUME_STEP=""
  for pair in \
    "00-config.yaml|Step 0 (test plan creation + CI auto-confirm)" \
    "01-doc-review.md|Step 3 (Documentation Analysis / doc-reviewer)" \
    "03-test-results.md|Step 4 (Functional Testing / fvr-tester)" \
    "04-perf-results.md|Step 5 (Performance Testing / perf-tester)" \
    "05-quality-review.md|Step 6 (Quality Review / quality-reviewer)" \
    "06-final-report.md|Step 7 (Report Generation / report-generator)" \
    "07-grounded-report.md|Step 8 (Grounding Verification, CI auto-KEEP)"
  do
    artifact="${pair%%|*}"
    stepdesc="${pair#*|}"
    if [[ ! -s "$LOG_DIR/$artifact" ]]; then
      RESUME_STEP="$stepdesc"
      RESUME_MISSING="$artifact"
      break
    fi
  done
  if [[ -z "$RESUME_STEP" ]]; then
    echo "[run-vss-fvr] Nothing to resume: every pipeline artifact through" >&2
    echo "07-grounded-report.md already exists in $LOG_DIR." >&2
    echo "If Step 9 (cleanup/publish) is what's missing, finish it manually --" >&2
    echo "re-invoking the whole agent risks it redoing completed work." >&2
    exit 0
  fi
  echo "[run-vss-fvr] First missing artifact: $RESUME_MISSING -> resuming at $RESUME_STEP"
  RESUME_CONTEXT="RESUMING AN INTERRUPTED RUN. This log directory already contains
the artifacts from every completed earlier step -- READ them, do not redo
them, and do not overwrite them. The first missing artifact is
'${RESUME_MISSING}', so resume the pipeline at: ${RESUME_STEP}.
Everything before that point is already done and must be treated as
authoritative input. The product may or may not still be deployed on the
SSH target -- check its actual state before assuming either way, and
redeploy only if the step you're resuming genuinely needs it running."
fi

if [[ -n "$RESUME_DIR" && -s "$LOG_DIR/00-config.yaml" ]]; then
  # Never re-copy a plan over a resumed run's existing one: later steps'
  # artifacts were produced against THAT plan, so replacing it mid-run would
  # silently invalidate everything already on disk.
  echo "[run-vss-fvr] Resume: keeping the existing 00-config.yaml as-is."
  PLAN_CONTEXT="This run's test plan already exists at ${LOG_DIR}/00-config.yaml
and the artifacts already on disk were produced against it. Reuse it exactly
as-is -- do not invoke test-plan-creator and do not modify the plan."
elif [[ -n "$MATCHED_PLAN" ]]; then
  echo "[run-vss-fvr] Fast path: reusing pre-baked confirmed plan $MATCHED_PLAN"
  cp "$MATCHED_PLAN" "$LOG_DIR/00-config.yaml"
  PLAN_CONTEXT="A pre-confirmed test plan has already been copied to
${LOG_DIR}/00-config.yaml (status: confirmed). Per ci/CI_OVERRIDE.md's Step 0
fast path, reuse it as-is -- do not invoke test-plan-creator, do not run the
live confirmation gate. Start the pipeline at Step 1 (Setup)."
else
  echo "[run-vss-fvr] No pre-baked plan matched for profile=$PROFILE hardware=$DETECTED_GPUS mode=(llm=$LLM_MODE,vlm=$VLM_MODE)."
  echo "[run-vss-fvr] Falling back to CI-driven plan generation (see ci/CI_OVERRIDE.md)."
  PLAN_CONTEXT="No pre-baked plan matched this profile/hardware/mode combination.
Run Step 0 for real: invoke test-plan-creator against the VSS Blueprint's
published documentation (start at:
${DOCS_URLS_TEXT}
and follow whatever these pages link to) for developer profile
'${PROFILE}' on detected hardware [${DETECTED_GPUS}], deploy mode
LLM_MODE=${LLM_MODE} VLM_MODE=${VLM_MODE} (provider hints:
llm=${LLM_PROVIDER:-n/a} vlm=${VLM_PROVIDER:-n/a}). A local reference
checkout of the VSS repo exists at ${VSS_REPO_LOCAL_REFERENCE} for reading
skill reference docs (skills/vss-deploy-profile/references/*.md) and
profile .env templates ONLY -- it has not been installed on the SSH target
and is not itself the subject of the test. Save the plan to
${LOG_DIR}/00-config.yaml. Per ci/CI_OVERRIDE.md's Step 0 generation path,
auto-confirm it yourself (set status: confirmed, confirmed_at, confirmed_run)
once test-plan-creator returns its summary -- do not wait for a human."
fi

# --stop-after=preflight never invokes the agent at all: preflight has already
# run above, so there is nothing left to validate. Exiting here is what makes
# it the near-free "did my env/SSH/GPU/plan-matching wiring survive that
# change?" check.
if [[ "$STOP_AFTER" == "preflight" ]]; then
  echo "stopped-after-preflight (TESTING MODE -- not a review)" > "$LOG_DIR/CI-STATUS"
  echo "[run-vss-fvr] --stop-after=preflight: preflight passed, agent NOT invoked."
  echo "[run-vss-fvr] Detected GPUs: $DETECTED_GPUS"
  echo "[run-vss-fvr] Matched plan: ${MATCHED_PLAN:-<none -- would generate>}"
  echo "[run-vss-fvr] Log directory: $LOG_DIR"
  exit 0
fi

# For the later stop points the agent DOES run, so the stop instruction has to
# reach it in the prompt. Kept as an explicit instruction rather than a
# wall-clock timeout so the agent still finishes its current step cleanly and
# writes that step's artifact before halting.
STOP_CONTEXT=""
case "$STOP_AFTER" in
  plan)
    STOP_CONTEXT="TESTING MODE -- STOP EARLY. Run Step 0 only: produce and
CI-auto-confirm the test plan at ${LOG_DIR}/00-config.yaml, then STOP
IMMEDIATELY. Do not run Pre-Flight, do not deploy anything on the SSH
target, do not invoke any further subagent. End your final message with the
literal string CI-STOPPED-AFTER-PLAN."
    ;;
  deploy)
    STOP_CONTEXT="TESTING MODE -- STOP EARLY. Run through Step 2 (Pre-Flight,
including the real deploy on the SSH target) and then STOP IMMEDIATELY. Do
not run Documentation Analysis, functional testing, or anything later. Leave
the product deployed -- the driver script tears it down itself. End your
final message with the literal string CI-STOPPED-AFTER-DEPLOY."
    ;;
  test)
    STOP_CONTEXT="TESTING MODE -- STOP EARLY. Run through Step 4 (Functional
Testing, writing 03-test-results.md) and then STOP IMMEDIATELY. Do not run
performance testing, quality review, report generation, or grounding. End
your final message with the literal string CI-STOPPED-AFTER-TEST."
    ;;
esac

# --- Forced, driver-level teardown ------------------------------------------
# AGENTS.md Step 9 already has the agent tear its own deploy down as part of
# the normal pipeline -- this is a backstop, not a replacement. It runs
# UNCONDITIONALLY (success, failure, blocked, or timeout) so a box is never
# left dirty because a run died before reaching its own Step 9, and it's
# independently verified rather than trusted on the agent's say-so.
REMOTE_VSS_DIR="${REMOTE_VSS_REPO_DIR:-~/video-search-and-summarization}"
# The teardown command itself is product-specific, so it's overridable rather
# than hardwired -- any product whose teardown is a single command run from
# its checkout directory works here without touching this script. Runs inside
# `cd $REMOTE_VSS_DIR` on the remote box.
REMOTE_TEARDOWN_CMD="${REMOTE_TEARDOWN_CMD:-deploy/docker/scripts/dev-profile.sh down}"
# The teardown-verification check below must only look at containers the
# product itself deployed, not every container on the box -- some GPU cloud
# providers (observed: Crusoe-backed Brev boxes) run their own permanent
# monitoring sidecars (vector, dcgm-exporter, log-collector,
# metrics-exporter) that have nothing to do with the product and are never
# going away. A raw `docker ps -aq` count treats those as "dirty" forever,
# permanently misreporting every future run -- even a perfectly clean one --
# as failed (AI_ASSETS/DECISIONS.md I23). Scoped to the product's own compose
# project via the standard `com.docker.compose.project` label; overridable
# for products that aren't VSS.
REMOTE_VSS_COMPOSE_PROJECT="${REMOTE_VSS_COMPOSE_PROJECT:-mdx}"

forced_teardown() {
  echo "[run-vss-fvr] Forced teardown: tearing down '${PROFILE}' on ${SERVER_HOST} (backstop, independent of the agent's own Step 9 cleanup)..."
  local teardown_log="$LOG_DIR/CI-TEARDOWN.log"
  # -o ConnectTimeout: without it, a broken/half-open local network state
  # (e.g. right after this machine wakes from sleep -- AI_ASSETS/DECISIONS.md
  # I16) leaves ssh free to hang on the OS's own multi-hour TCP retransmit
  # timeout instead of failing fast. I16 observed the verification call below
  # take ~2.5h to return for exactly this reason before this fix.
  local ssh_opts=(-i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
  # Image pruning (-a: every image not used by a running container, not just
  # dangling layers) runs here too, unconditionally, same as the container
  # teardown above. A single-profile run never needed this -- pulled images
  # sitting in the cache between runs was a feature, avoiding a re-pull. A
  # multi-cell matrix run is different: every cell pulls a different set of
  # ~60-80GB NIM images with nothing ever reclaiming space between them, and
  # that filled the disk mid-matrix (AI_ASSETS/DECISIONS.md I28) -- the
  # search cell's own diagnosis of the failure recommended relocating
  # Docker's data-root to the box's larger partition instead, but pruning
  # here is the fix that travels with the driver rather than depending on
  # one-time host setup. Trades away the cross-cell pull-cache benefit
  # entirely (every cell now re-pulls from scratch) in exchange for the
  # matrix actually being able to finish.
  ssh "${ssh_opts[@]}" \
    "${SERVER_USER}@${SERVER_HOST}" \
    "cd ${REMOTE_VSS_DIR} 2>/dev/null && ${REMOTE_TEARDOWN_CMD}; \
     echo '--- post-teardown docker ps ---'; docker ps -a --format '{{.Names}}\t{{.Status}}'; \
     echo '--- docker image prune ---'; docker image prune -af 2>&1" \
    > "$teardown_log" 2>&1
  # Bounded retry (not infinite, not a single shot): a teardown SSH session
  # that just broke mid-command (I16's "Broken pipe") may need the local
  # network a few seconds to settle before a fresh connection succeeds --
  # give it a few tries with a fast per-attempt timeout rather than either
  # hanging indefinitely on one attempt or giving up on the first blip.
  local remaining="" attempt
  for attempt in 1 2 3 4 5; do
    remaining="$(ssh "${ssh_opts[@]}" \
      "${SERVER_USER}@${SERVER_HOST}" \
      "docker ps -aq --filter 'label=com.docker.compose.project=${REMOTE_VSS_COMPOSE_PROJECT}' | wc -l" \
      2>>"$teardown_log" | tr -d ' ')"
    [[ -n "$remaining" ]] && break
    echo "[run-vss-fvr] Teardown-verification SSH attempt $attempt/5 failed/empty -- retrying in 15s..." >&2
    sleep 15
  done
  if [[ "$remaining" == "0" ]]; then
    echo "[run-vss-fvr] Teardown verified clean: 0 '${REMOTE_VSS_COMPOSE_PROJECT}' containers remaining on ${SERVER_HOST} (other host infrastructure, if any, is out of scope)."
    echo "clean" > "$LOG_DIR/CI-TEARDOWN-STATUS"
    return 0
  elif [[ -z "$remaining" ]]; then
    echo "[run-vss-fvr] WARNING: could not verify teardown -- SSH to ${SERVER_HOST} did not" >&2
    echo "succeed after 5 attempts. Box state UNKNOWN, not confirmed clean. See $teardown_log" >&2
    echo "unknown (ssh unreachable after 5 attempts)" > "$LOG_DIR/CI-TEARDOWN-STATUS"
    return 1
  else
    echo "[run-vss-fvr] WARNING: teardown left ${remaining} '${REMOTE_VSS_COMPOSE_PROJECT}' container(s) running on ${SERVER_HOST}. See $teardown_log" >&2
    echo "dirty (${remaining} containers)" > "$LOG_DIR/CI-TEARDOWN-STATUS"
    return 1
  fi
}

# --- Step 3: invoke Claude Code non-interactively ---------------------------
PROMPT="Run the FVR pipeline defined in AGENTS.md, unattended, for the VSS
Blueprint developer profile '${PROFILE}'.

IMPORTANT: VSS has NOT been installed or cloned onto the SSH target
(${SERVER_HOST}) by this driver script -- nothing has pre-provisioned it
there. Do not assume a working checkout exists. Getting VSS onto that box is
your own Doc-Faithful Testing responsibility: follow the product's published
documentation (starting at:
${DOCS_URLS_TEXT}
) and execute its
documented setup steps for real over SSH, including the git-clone/git-lfs
steps themselves -- that IS part of what this review tests, not a
prerequisite to skip past. If a checkout already exists at
~/video-search-and-summarization on the box (e.g. left over from a prior
run whose forced-teardown only stopped containers, not the checkout), decide
how to handle it the way the product's own redeploy/teardown guidance
describes -- do not silently assume it's clean or stale.

FVR skill repo (this repo, local to wherever you're running): ${FVR_SKILL_REPO}
Log directory for this run: ${LOG_DIR}
Server: SSH target already verified reachable with GPUs [${DETECTED_GPUS}]
by scripts/ci/vss-preflight.py.

${PLAN_CONTEXT}

${RESUME_CONTEXT}

${STOP_CONTEXT}

Follow every step of AGENTS.md's Review Workflow in order (Setup, Pre-Flight,
Documentation Analysis, Functional Testing, Feature Testing, Agentic
Readiness, UI Capture if applicable, Performance Testing, Quality Review,
Report Generation, Grounding Verification, Cleanup). This is a CI run: apply
every override in ci/CI_OVERRIDE.md at the points AGENTS.md would normally
block on a human (Step 0 confirmation, Step 1b feature clarifications, Step 8
grounding). Do not wait on stdin at any point. Still run Step 9's own
teardown/cleanup as AGENTS.md describes -- the CI driver independently
verifies and force-retries teardown after you finish, but your own Step 9
is the first line of defense and must not be skipped. If ci/CI_OVERRIDE.md's
fail-closed clause is triggered, write logs/.../CI-BLOCKED.md explaining
exactly what's unresolved and end your final message with the literal string
CI-RUN-BLOCKED so the driver script can detect it."

# Real-time visibility: default `-p`/`--output-format text` only prints the
# FINAL result after the whole session ends -- a multi-hour unattended run
# would otherwise be a black box until it finishes or dies. stream-json
# gives incremental NDJSON events as they happen; `--verbose` is required
# alongside it. The raw NDJSON is the authoritative record (AGENTS.md's
# "every command is logged with full output" principle applies to this
# invocation too); format_claude_stream() is a best-effort human-readable
# view over it for whoever tails ci-driver-transcript.log, not a substitute.
CLAUDE_ARGS=(
  -p "$PROMPT"
  --append-system-prompt "$(cat "$SCRIPT_DIR/CI_OVERRIDE.md")"
  --permission-mode bypassPermissions
  --output-format stream-json
  --include-partial-messages
  --verbose
)

# Defense-in-depth against the print-mode background-task ceiling: `claude
# -p` force-terminates the whole process (mid-deploy, mid-test -- not at a
# clean stopping point) if any background task is still outstanding after
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS (default 600_000 = 10 min). CI_OVERRIDE.md
# instructs the agent never to background a subagent it's about to depend
# on, which is the real fix -- this is a second line of defense in case that
# instruction is ever violated. Safe to wait indefinitely here because the
# outer `timeout ${TIMEOUT_HOURS}h` (see run_claude_with_timeout below) is
# already the hard backstop on total run length -- see run6's forced kill at
# ~40min into a run that was otherwise healthy (containers up and passing
# health checks) for what happens without this.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

format_claude_stream() {
  if ! command -v jq >/dev/null 2>&1; then
    cat # no jq -- passthrough raw NDJSON rather than losing the stream
    return
  fi
  jq -R -r '
    (try fromjson catch empty) as $e
    | select($e != null)
    | if $e.type == "assistant" then
        ($e.message.content // [])[]
        | if .type == "text" then "[assistant] " + .text
          elif .type == "tool_use" then "[tool_use] " + .name + " " + (.input | tostring)
          else empty end
      elif $e.type == "user" then
        ($e.message.content // [])[]
        | if .type == "tool_result" then
            "[tool_result] " + ((.content | tostring)[0:500])
          else empty end
      elif $e.type == "result" then
        "[result] " + ($e.result // ($e | tostring))
      elif $e.type == "system" then
        "[system] " + ($e.subtype // "event")
      else
        ($e | tostring)
      end
  ' 2>/dev/null || cat
}

# Portable timeout wrapper. GNU `timeout` doesn't ship on macOS (the CI
# workflow's Linux runners have it; local/dev testing may not). Falls back
# to `gtimeout` (Homebrew coreutils), then to a manual background+watchdog
# implementation so this script works the same everywhere rather than
# failing with "timeout: command not found" on a bare macOS box.
#
# claude's stdout/stderr are each independently teed via process
# substitution rather than a `cmd | tee` pipe -- this keeps `claude` as the
# direct, single foreground (or backgrounded) command, so its exit code is
# available directly via `$?`/`wait` without the PIPESTATUS-doesn't-survive-
# backgrounding workaround a plain pipe would need in the manual-watchdog
# tier. stdout (the NDJSON) and stderr (warnings/errors, e.g. the auth
# failure this was built to surface faster) are kept on separate files but
# both also stream into the same human transcript.
run_claude_with_timeout() {
  local timeout_seconds=$(( TIMEOUT_HOURS * 3600 ))

  if command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_HOURS}h" claude "${CLAUDE_ARGS[@]}" \
      > >(tee "$LOG_DIR/claude-stream.jsonl" | format_claude_stream >> "$LOG_DIR/ci-driver-transcript.log") \
      2> >(tee "$LOG_DIR/claude-stderr.log" >> "$LOG_DIR/ci-driver-transcript.log")
    CLAUDE_EXIT=$?
    return
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${TIMEOUT_HOURS}h" claude "${CLAUDE_ARGS[@]}" \
      > >(tee "$LOG_DIR/claude-stream.jsonl" | format_claude_stream >> "$LOG_DIR/ci-driver-transcript.log") \
      2> >(tee "$LOG_DIR/claude-stderr.log" >> "$LOG_DIR/ci-driver-transcript.log")
    CLAUDE_EXIT=$?
    return
  fi

  echo "[run-vss-fvr] Neither 'timeout' nor 'gtimeout' found -- using a" >&2
  echo "manual timeout watchdog. Install GNU coreutils (brew install" >&2
  echo "coreutils) to get the standard behavior instead." >&2
  local was_set_m=0
  case "$-" in *m*) was_set_m=1 ;; esac
  set -m
  claude "${CLAUDE_ARGS[@]}" \
    > >(tee "$LOG_DIR/claude-stream.jsonl" | format_claude_stream >> "$LOG_DIR/ci-driver-transcript.log") \
    2> >(tee "$LOG_DIR/claude-stderr.log" >> "$LOG_DIR/ci-driver-transcript.log") &
  local claude_pid=$!
  (
    sleep "$timeout_seconds"
    if kill -0 "$claude_pid" 2>/dev/null; then
      echo "[run-vss-fvr] Watchdog: ${TIMEOUT_HOURS}h elapsed, killing claude." >&2
      kill -TERM -- -"$claude_pid" 2>/dev/null || kill -TERM "$claude_pid" 2>/dev/null
    fi
  ) &
  local watchdog_pid=$!
  if wait "$claude_pid" 2>/dev/null; then
    CLAUDE_EXIT=0
  else
    CLAUDE_EXIT=$?
  fi
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  [[ $was_set_m -eq 0 ]] && set +m
}

echo "[run-vss-fvr] Invoking claude (timeout ${TIMEOUT_HOURS}h)..."
# --permission-mode bypassPermissions: the pipeline runs many Bash/SSH/docker
# commands via subagents; a CI job with no human to approve prompts must not
# block on tool-use confirmation. Confirm this flag name against the
# installed Claude Code CLI version before relying on it (see plan Part 4).
run_claude_with_timeout
# Small buffer for the `> >(...)` process-substitution jobs above to finish
# flushing their tee/jq output to disk -- claude's own exit code is already
# captured synchronously, but the log files they write to can lag a beat.
sleep 1
T_PIPELINE_END="$(date -u +%s)"

CI_STATUS="ok"
FINAL_EXIT=0
if [[ $CLAUDE_EXIT -eq 124 ]]; then
  echo "[run-vss-fvr] TIMED OUT after ${TIMEOUT_HOURS}h." >&2
  CI_STATUS="timeout"
  FINAL_EXIT=124
elif grep -q "Background tasks still running after" "$LOG_DIR/claude-stderr.log" 2>/dev/null; then
  # claude -p's own print-mode ceiling force-killed the process while a
  # background subagent was still outstanding (see CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  # above). Distinct from "blocked": the agent never hit CI_OVERRIDE.md's
  # fail-closed clause, the CLI killed a run that may have been perfectly
  # healthy mid-flight -- do not conflate the two, they need different
  # follow-up (a workflow bug here vs. a genuine unresolved ambiguity there).
  echo "[run-vss-fvr] claude -p force-terminated the run: a background" >&2
  echo "subagent was still outstanding past the print-mode wait ceiling." >&2
  CI_STATUS="terminated-bg-task-timeout"
  FINAL_EXIT=1
elif [[ -f "$LOG_DIR/CI-SKIPPED-INFEASIBLE.md" ]]; then
  # CI_OVERRIDE.md's Step 0 addition: the matrix intentionally includes
  # mode combinations that may not fit every box it runs on. A cell
  # correctly recognizing "this doesn't fit THIS hardware" and stopping
  # before deploying anything is a correct, cheap, expected outcome for
  # some cells -- not a failure, and not "incomplete" (which implies the
  # pipeline died mid-flight, not that it made a deliberate early stop).
  echo "[run-vss-fvr] Requested mode combination does not fit the detected" >&2
  echo "hardware -- see CI-SKIPPED-INFEASIBLE.md in $LOG_DIR." >&2
  CI_STATUS="skipped-hardware-infeasible"
elif [[ -f "$LOG_DIR/CI-BLOCKED.md" ]]; then
  # Check the artifact CI_OVERRIDE.md's fail-closed clause actually
  # instructs the agent to write, not a raw string grep over the full
  # transcript -- that grep matches its own false positives (e.g. a
  # mid-run context-compaction summary that quotes CI_OVERRIDE.md's
  # instructions verbatim, including the literal token "CI-RUN-BLOCKED",
  # without the agent ever having reached the fail-closed clause for real).
  echo "[run-vss-fvr] Run hit the fail-closed clause (see CI-BLOCKED.md in $LOG_DIR)." >&2
  CI_STATUS="blocked"
  FINAL_EXIT=1
elif [[ $CLAUDE_EXIT -ne 0 ]]; then
  echo "[run-vss-fvr] claude exited non-zero ($CLAUDE_EXIT)." >&2
  CI_STATUS="failed"
  FINAL_EXIT="$CLAUDE_EXIT"
fi
# A clean exit is NOT proof the pipeline ran. `claude -p` exits
# subtype:success / stop_reason:end_turn whenever the agent simply ends its
# turn -- including mid-pipeline, e.g. after narrating "waiting for the deploy
# to finish". Two real cells did exactly that and were recorded `ok` despite
# producing no report at all, at ~$25 combined. The final artifact's existence
# is the only trustworthy completion signal, so check it rather than the exit
# code. (Skipped for --stop-after, which has no report by design.)
if [[ -z "$STOP_AFTER" && -z "$RESUME_DIR" && "$CI_STATUS" == "ok" ]] \
   && [[ ! -s "$LOG_DIR/06-final-report.md" && ! -s "$LOG_DIR/07-grounded-report.md" ]]; then
  echo "[run-vss-fvr] INCOMPLETE: claude exited cleanly but no final report was" >&2
  echo "produced -- the agent ended its turn before finishing the pipeline." >&2
  echo "Check the last 'result' event in claude-stream.jsonl for where it stopped;" >&2
  echo "a message like 'waiting for X to finish' means it backgrounded work and" >&2
  echo "ended its turn, which in headless -p mode ends the run." >&2
  CI_STATUS="incomplete-no-report"
  [[ "$FINAL_EXIT" -eq 0 ]] && FINAL_EXIT=1
fi

if [[ -n "$STOP_AFTER" && "$CI_STATUS" == "ok" ]]; then
  # A deliberately-truncated run must never record a status that reads like a
  # completed review -- nothing downstream (or later human) should be able to
  # mistake a 5-minute wiring check for a real result.
  CI_STATUS="stopped-after-${STOP_AFTER} (TESTING MODE -- not a review)"
fi
echo "$CI_STATUS" > "$LOG_DIR/CI-STATUS"

# --- Step 3b: report integrity gate ----------------------------------------
# Replaces the self-limiting discipline a human Step 8 reviewer used to
# supply: an unattended run was found to silently drop its own quality
# reviewer's untested-items list and to promote single bugs into the
# "patterns only" Top Issues section (AI_ASSETS/DECISIONS.md I18). These are
# mechanical rule violations, so they get a mechanical check rather than a
# human. Advisory by default -- it reports and records, and only fails the
# run when FVR_ENFORCE_REPORT_INTEGRITY=true -- because a false positive
# here would throw away an otherwise-complete multi-hour run.
INTEGRITY_SCRIPT="$SCRIPT_DIR/check-report-integrity.py"
if [[ -z "$STOP_AFTER" && -f "$INTEGRITY_SCRIPT" ]] \
   && { [[ -s "$LOG_DIR/07-grounded-report.md" ]] || [[ -s "$LOG_DIR/06-final-report.md" ]]; }; then
  echo "[run-vss-fvr] Checking report integrity (Scope Limits, Top-Issue patterns, disclosures)..."
  python3 "$INTEGRITY_SCRIPT" --log-dir "$LOG_DIR" > "$LOG_DIR/CI-REPORT-INTEGRITY.txt" 2>&1
  INTEGRITY_EXIT=$?
  cat "$LOG_DIR/CI-REPORT-INTEGRITY.txt"
  python3 "$INTEGRITY_SCRIPT" --log-dir "$LOG_DIR" --json \
    > "$LOG_DIR/CI-REPORT-INTEGRITY.json" 2>/dev/null || true
  if [[ $INTEGRITY_EXIT -ne 0 ]]; then
    if [[ "${FVR_ENFORCE_REPORT_INTEGRITY:-false}" == "true" ]]; then
      echo "[run-vss-fvr] Report integrity FAILED and enforcement is on -- marking run failed." >&2
      CI_STATUS="report-integrity-failed"
      echo "$CI_STATUS" > "$LOG_DIR/CI-STATUS"
      [[ "$FINAL_EXIT" -eq 0 ]] && FINAL_EXIT=1
    else
      echo "[run-vss-fvr] WARNING: report integrity check found problems (advisory --" >&2
      echo "set FVR_ENFORCE_REPORT_INTEGRITY=true to make this fail the run)." >&2
      echo "See $LOG_DIR/CI-REPORT-INTEGRITY.txt" >&2
    fi
  fi
fi

# --- Step 4: timing -----------------------------------------------------
# "SSH-to-report-generation" per the user's ask: T0 = the SSH+GPU preflight
# check above (the earliest point this run actually touched the box), T1 =
# the mtime of 06-final-report.md (Step 7's output) if the run got that far.
# Also record total wall-clock through pipeline completion for comparison.
REPORT_FILE="$LOG_DIR/06-final-report.md"
{
  echo "# CI Timing -- ${PROFILE} ($(date -u -d "@$T_SSH_VERIFIED" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$T_SSH_VERIFIED" +%Y-%m-%dT%H:%M:%SZ))"
  echo ""
  echo "- SSH+GPU preflight verified: $(date -u -d "@$T_SSH_VERIFIED" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$T_SSH_VERIFIED" +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -f "$REPORT_FILE" ]]; then
    T_REPORT="$(stat -f %m "$REPORT_FILE" 2>/dev/null || stat -c %Y "$REPORT_FILE" 2>/dev/null)"
    echo "- 06-final-report.md written: $(date -u -d "@$T_REPORT" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$T_REPORT" +%Y-%m-%dT%H:%M:%SZ)"
    echo "- **SSH-to-report-generation: $((T_REPORT - T_SSH_VERIFIED)) seconds ($(( (T_REPORT - T_SSH_VERIFIED) / 60 )) min)**"
  else
    echo "- 06-final-report.md: NOT PRODUCED (run did not reach Step 7 -- status: $CI_STATUS)"
  fi
  echo "- Pipeline invocation ended: $(date -u -d "@$T_PIPELINE_END" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$T_PIPELINE_END" +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Total wall-clock (SSH-verified to pipeline end, incl. grounding+cleanup): $((T_PIPELINE_END - T_SSH_VERIFIED)) seconds ($(( (T_PIPELINE_END - T_SSH_VERIFIED) / 60 )) min)"
  echo ""
  echo "## Token & cost usage"
  echo ""
  # claude -p emits exactly one top-level {"type":"result",...} event per
  # invocation (the CLI's own session summary), containing usage/cost
  # aggregated across the orchestrator AND every subagent Task call it made
  # (modelUsage) -- this is a real number the CLI already computed, not
  # something this script derives itself. Parsed here (not left to a human
  # to dig out of a multi-MB NDJSON file) so cost-per-run is visible
  # alongside timing without a separate investigation every time.
  if command -v jq >/dev/null 2>&1 && [[ -f "$LOG_DIR/claude-stream.jsonl" ]]; then
    # -R + `try fromjson catch empty`: the stream occasionally contains a
    # malformed line (observed: 836 chars of whitespace). Plain `jq` aborts the
    # WHOLE file on the first parse error, which silently threw away a run's
    # cost/token totals and reported "no result event found" -- the same
    # defensive read format_claude_stream() already uses, missed here.
    RESULT_JSON="$(jq -R -c '(try fromjson catch empty) | select(.type=="result")' \
      "$LOG_DIR/claude-stream.jsonl" 2>/dev/null | tail -1)"
    if [[ -n "$RESULT_JSON" ]]; then
      echo "$RESULT_JSON" | jq -r '
        "- Total cost: $" + (.total_cost_usd | tostring) + " USD (top-level session; see modelUsage below for the orchestrator+subagents aggregate, which is usually higher)",
        "- Turns: " + (.num_turns | tostring) + " | stop_reason: " + .stop_reason + " | api duration: " + ((.duration_api_ms / 1000) | floor | tostring) + "s",
        "- Top-level usage: input=" + (.usage.input_tokens | tostring) + " output=" + (.usage.output_tokens | tostring) + " cache_read=" + (.usage.cache_read_input_tokens | tostring) + " cache_creation=" + (.usage.cache_creation_input_tokens | tostring),
        (.modelUsage // {} | to_entries[] |
          "- Model `" + .key + "`: input=" + (.value.inputTokens | tostring) +
          " output=" + (.value.outputTokens | tostring) +
          " cache_read=" + (.value.cacheReadInputTokens | tostring) +
          " cache_creation=" + (.value.cacheCreationInputTokens | tostring) +
          " cost=$" + (.value.costUSD | tostring))
      ' 2>/dev/null || echo "- (found a result event but could not parse its usage fields -- see raw: \`jq 'select(.type==\"result\")' $LOG_DIR/claude-stream.jsonl\`)"
    else
      echo "- No \`{\"type\":\"result\"}\` event found in claude-stream.jsonl -- run was likely force-terminated"
      echo "  before the CLI could emit its session summary (e.g. the 3h outer timeout, or the"
      echo "  print-mode background-task ceiling -- see CI-STATUS: $CI_STATUS). No cost/token total available for this run."
    fi
  else
    echo "- jq not available or claude-stream.jsonl missing -- skipped (raw usage may still be in claude-stream.jsonl)"
  fi
} | tee "$LOG_DIR/CI-TIMING.md"

# --- Step 5: forced teardown (always runs, regardless of pipeline outcome) --
if ! forced_teardown; then
  echo "[run-vss-fvr] Box was NOT left clean -- see CI-TEARDOWN.log. Marking run failed" \
       "so this doesn't silently contaminate the next run." >&2
  [[ "$FINAL_EXIT" -eq 0 ]] && FINAL_EXIT=1
  # CI-STATUS was already written above (before teardown ran) and, unlike
  # the incomplete-no-report/report-integrity-failed paths, was never
  # updated to reflect this -- so it could read "ok" on disk while the
  # process exit code (checked above) says failure. Only overwrite when it
  # was "ok": a more specific earlier failure reason (e.g.
  # report-integrity-failed) is more useful than this one and should win.
  if [[ "$CI_STATUS" == "ok" ]]; then
    CI_STATUS="teardown-not-clean (see CI-TEARDOWN-STATUS)"
    echo "$CI_STATUS" > "$LOG_DIR/CI-STATUS"
  fi
fi

echo "[run-vss-fvr] Done ($CI_STATUS). Log directory: $LOG_DIR"
exit "$FINAL_EXIT"
