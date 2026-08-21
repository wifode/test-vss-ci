#!/usr/bin/env bash
# Sequential FVR matrix runner: runs one profile across several LLM/VLM
# deployment-mode combinations, one full review per combination.
#
# Usage:
#   scripts/ci/run-fvr-matrix.sh <profile> [options]
#
#   --combo llm=<mode>,vlm=<mode>[,llm_provider=<p>][,vlm_provider=<p>]
#         Repeatable. An explicit cell to run. If you pass any --combo, ONLY
#         those run -- no auto-derivation, no filtering, no surprises.
#   --auto-combos
#         Derive cells from the detected GPU count using the documented
#         heuristic below instead of listing them by hand.
#   --allow-shared-gpu
#         With --auto-combos, permit the fully-local cell on a single-GPU
#         box (both models sharing one GPU). Off by default because it
#         OOMs on most real hardware/model pairs.
#   --timeout-hours N     Per-cell timeout passed through (default 3).
#   --docs-url URL        Repeatable, passed through to every cell. You can
#                         instead set $FVR_DOCS_URLS (comma-separated) once
#                         and every cell inherits it -- usually what you want
#                         for a matrix, since all cells should read the same
#                         source material. Pinning a docs version rather than
#                         '/latest/' matters here: cells run hours apart, and
#                         a docs update mid-matrix would otherwise give the
#                         last cell different inputs than the first.
#   --continue-on-failure Keep going after a cell fails (default: stop).
#   --dry-run             Print the cells that would run, then exit.
#
# Everything else (SERVER_HOST/SERVER_USER/SSH_KEY_PATH, credentials,
# FVR_PRODUCT_SLUG, REMOTE_TEARDOWN_CMD, ...) is read from the environment
# exactly as run-vss-fvr.sh reads it -- this wrapper adds no new
# configuration surface and hardcodes no product, GPU model, or host.
#
# WHY SEQUENTIAL, AND WHY SEPARATE RUNS PER CELL:
#   - One shared SSH box means parallel cells would fight over the same
#     GPUs. Real parallelism needs one box per cell, which is a separate
#     (deferred) provisioning question.
#   - Each cell gets its own log directory, its own report, and its own
#     verified teardown. A cell that fails doesn't corrupt or block the
#     others, and there's no single multi-hour session whose death loses
#     everything (which is exactly what happened to a single long run --
#     see AI_ASSETS/DECISIONS.md I16).
#   - The report format rates ONE deploy shape, so N cells legitimately
#     means N reports, not one merged document.
#
# COST WARNING: this is N x the cost and wall-clock of a single review.
# A 3-cell matrix has run to roughly $90-100 and ~6 hours. This is a
# nightly / on-demand job, never a per-push one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/run-vss-fvr.sh"

if [[ ! -x "$DRIVER" && ! -f "$DRIVER" ]]; then
  echo "FATAL: driver not found at $DRIVER" >&2
  exit 2
fi

PROFILE="${1:?usage: run-fvr-matrix.sh <profile> [--combo llm=X,vlm=Y ...] [--auto-combos]}"
shift || true

COMBOS=()
AUTO_COMBOS=false
ALLOW_SHARED_GPU=false
TIMEOUT_HOURS="3"
DOCS_URL_ARGS=()
CONTINUE_ON_FAILURE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --combo) COMBOS+=("$2"); shift 2 ;;
    --auto-combos) AUTO_COMBOS=true; shift ;;
    --allow-shared-gpu) ALLOW_SHARED_GPU=true; shift ;;
    --timeout-hours) TIMEOUT_HOURS="$2"; shift 2 ;;
    --docs-url) DOCS_URL_ARGS+=(--docs-url "$2"); shift 2 ;;
    --continue-on-failure) CONTINUE_ON_FAILURE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ${#COMBOS[@]} -eq 0 && "$AUTO_COMBOS" != "true" ]]; then
  echo "FATAL: pass at least one --combo, or --auto-combos to derive them." >&2
  echo "" >&2
  echo "Explicit is preferred: which mode combinations are actually worth" >&2
  echo "testing depends on the product's own sizing guidance, which this" >&2
  echo "generic wrapper cannot know. --auto-combos applies only a coarse" >&2
  echo "GPU-count heuristic (see --help text in this file)." >&2
  exit 2
fi

# --- Detect GPU count (only needed for --auto-combos) -----------------------
# Uses the same SSH env vars the driver uses. Deliberately counts GPUs
# without interpreting their model names: any GPU type on any host works,
# and nothing here needs updating when new hardware shows up.
detect_gpu_count() {
  ssh -i "${SSH_KEY_PATH:?SSH_KEY_PATH must be set}" \
      -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
      "${SERVER_USER:?SERVER_USER must be set}@${SERVER_HOST:?SERVER_HOST must be set}" \
      "nvidia-smi --query-gpu=name --format=csv,noheader | wc -l" 2>/dev/null | tr -d ' '
}

if [[ "$AUTO_COMBOS" == "true" ]]; then
  echo "[matrix] Detecting GPU count on ${SERVER_HOST:-<unset>}..."
  GPU_COUNT="$(detect_gpu_count)"
  if [[ -z "$GPU_COUNT" || "$GPU_COUNT" == "0" ]]; then
    echo "FATAL: could not detect any GPUs on the target over SSH." >&2
    echo "(--auto-combos needs a GPU count to decide which cells are viable;" >&2
    echo "pass explicit --combo flags instead if the target has no GPUs or is" >&2
    echo "unreachable from here.)" >&2
    exit 1
  fi
  echo "[matrix] Detected ${GPU_COUNT} GPU(s)."

  # HEURISTIC, deliberately coarse and stated out loud rather than hidden:
  # the only thing a product-agnostic wrapper can safely infer is that
  # running BOTH models locally needs somewhere to put them. With 2+ GPUs
  # that's one model per GPU. With 1 GPU it means sharing, which OOMs on
  # most real model pairs -- so it's opt-in via --allow-shared-gpu.
  # Everything else (which remote provider, whether a given profile even
  # supports a mode) is the test plan's job, not this script's.
  COMBOS=("llm=remote,vlm=local" "llm=local,vlm=remote" "llm=remote,vlm=remote")
  if [[ "$GPU_COUNT" -ge 2 || "$ALLOW_SHARED_GPU" == "true" ]]; then
    COMBOS=("llm=local,vlm=local" "${COMBOS[@]}")
  else
    echo "[matrix] Skipping the fully-local cell: only 1 GPU detected and" >&2
    echo "--allow-shared-gpu was not passed. Pass it to test the shared-GPU" >&2
    echo "path anyway (expect OOM on most model pairs)." >&2
  fi
fi

# --- Parse combos into runnable argument sets -------------------------------
parse_combo() {
  # Sets COMBO_LLM/COMBO_VLM/COMBO_LLM_PROVIDER/COMBO_VLM_PROVIDER, or
  # returns 1 on a malformed spec.
  local spec="$1" kv k v
  COMBO_LLM=""; COMBO_VLM=""; COMBO_LLM_PROVIDER=""; COMBO_VLM_PROVIDER=""
  local IFS=','
  for kv in $spec; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      llm) COMBO_LLM="$v" ;;
      vlm) COMBO_VLM="$v" ;;
      llm_provider) COMBO_LLM_PROVIDER="$v" ;;
      vlm_provider) COMBO_VLM_PROVIDER="$v" ;;
      *) echo "  unknown key '$k' in combo '$spec'" >&2; return 1 ;;
    esac
  done
  [[ -n "$COMBO_LLM" && -n "$COMBO_VLM" ]] || {
    echo "  combo '$spec' must set both llm= and vlm=" >&2; return 1; }
  return 0
}

# Filesystem-safe name for a cell, e.g. llm-remote-nvidia_vlm-local.
# Providers are included only when set, so they disambiguate combos that
# differ solely by provider rather than padding every name.
cell_slug() {
  local s="llm-${COMBO_LLM}"
  [[ -n "$COMBO_LLM_PROVIDER" ]] && s+="-${COMBO_LLM_PROVIDER}"
  s+="_vlm-${COMBO_VLM}"
  [[ -n "$COMBO_VLM_PROVIDER" ]] && s+="-${COMBO_VLM_PROVIDER}"
  printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '-'
}

echo ""
echo "[matrix] Profile: $PROFILE"
echo "[matrix] Cells to run (sequentially): ${#COMBOS[@]}"
for spec in "${COMBOS[@]}"; do
  if ! parse_combo "$spec"; then
    echo "FATAL: malformed --combo: $spec" >&2
    exit 2
  fi
  printf '  - %-56s -> %s/\n' \
    "llm=$COMBO_LLM vlm=$COMBO_VLM${COMBO_LLM_PROVIDER:+ llm_provider=$COMBO_LLM_PROVIDER}${COMBO_VLM_PROVIDER:+ vlm_provider=$COMBO_VLM_PROVIDER}" \
    "$(cell_slug)"
done
echo ""
echo "[matrix] COST: this runs ${#COMBOS[@]} full reviews back to back."
echo "[matrix] Budget roughly ${#COMBOS[@]}x a single run's time and spend."
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[matrix] --dry-run: nothing executed."
  exit 0
fi

# --- Resolve ONE parent directory for this whole matrix run -----------------
# All cells live under it, each in a subdirectory named for its combination,
# so a run reads as one grouped unit:
#
#   logs/vss-base-2026-08-20-matrix/
#     llm-local_vlm-local/          <- full FVR artifacts for that cell
#     llm-remote-nvidia_vlm-local/
#     matrix-summary.md
#
# The -runN collision rule is applied HERE, to the parent, exactly once --
# never per cell. Previously each cell resolved its own logs/<...>-runN
# directory independently, which scattered one logical matrix run across
# sibling directories whose names said nothing about which combination they
# held or which run they belonged to.
FVR_SKILL_REPO="${FVR_SKILL_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MATRIX_BASE="${FVR_PRODUCT_SLUG:-vss}-${PROFILE}-$(date -u +%Y-%m-%d)-matrix"
MATRIX_DIR="$FVR_SKILL_REPO/logs/${MATRIX_BASE}"
_n=2
while [[ -d "$MATRIX_DIR" ]]; do
  MATRIX_DIR="$FVR_SKILL_REPO/logs/${MATRIX_BASE}-run${_n}"
  _n=$((_n + 1))
done
mkdir -p "$MATRIX_DIR"
echo "[matrix] Run directory: $MATRIX_DIR"
echo ""

# --- Run each cell ----------------------------------------------------------
MATRIX_START="$(date -u +%s)"
declare -a CELL_RESULTS=()
FAILED_CELLS=0

for spec in "${COMBOS[@]}"; do
  parse_combo "$spec"
  CELL_LABEL="llm=${COMBO_LLM},vlm=${COMBO_VLM}"
  CELL_SLUG="$(cell_slug)"
  CELL_DIR="$MATRIX_DIR/$CELL_SLUG"
  # Defensive: two combos should never slug identically, but if they somehow
  # do, keep them separate rather than letting one overwrite the other.
  _d=2
  while [[ -d "$CELL_DIR" ]]; do
    CELL_DIR="$MATRIX_DIR/${CELL_SLUG}-${_d}"
    _d=$((_d + 1))
  done

  echo ""
  echo "=============================================================="
  echo "[matrix] CELL $((${#CELL_RESULTS[@]} + 1))/${#COMBOS[@]}: $CELL_LABEL"
  echo "[matrix] -> $CELL_DIR"
  echo "=============================================================="

  CELL_START="$(date -u +%s)"
  bash "$DRIVER" "$PROFILE" \
    --llm-mode "$COMBO_LLM" \
    --vlm-mode "$COMBO_VLM" \
    --llm-provider "$COMBO_LLM_PROVIDER" \
    --vlm-provider "$COMBO_VLM_PROVIDER" \
    --timeout-hours "$TIMEOUT_HOURS" \
    --log-dir "$CELL_DIR" \
    "${DOCS_URL_ARGS[@]+"${DOCS_URL_ARGS[@]}"}"
  CELL_EXIT=$?
  CELL_ELAPSED=$(( $(date -u +%s) - CELL_START ))

  CELL_STATUS_FILE="$(cat "$CELL_DIR/CI-STATUS" 2>/dev/null || echo "none")"
  if [[ $CELL_EXIT -eq 0 ]]; then
    CELL_RESULTS+=("PASS|$CELL_LABEL|${CELL_ELAPSED}s|$(basename "$CELL_DIR")|$CELL_STATUS_FILE")
    echo "[matrix] Cell PASSED: $CELL_LABEL ($((CELL_ELAPSED / 60)) min)"
  else
    CELL_RESULTS+=("FAIL|$CELL_LABEL|${CELL_ELAPSED}s|$(basename "$CELL_DIR")|$CELL_STATUS_FILE")
    FAILED_CELLS=$((FAILED_CELLS + 1))
    echo "[matrix] Cell FAILED: $CELL_LABEL (exit $CELL_EXIT, $((CELL_ELAPSED / 60)) min)" >&2
    if [[ "$CONTINUE_ON_FAILURE" != "true" ]]; then
      echo "[matrix] Stopping: a cell failed and --continue-on-failure was not set." >&2
      echo "[matrix] The driver's own forced teardown already ran for this cell," >&2
      echo "[matrix] so the box should be clean -- check its CI-TEARDOWN-STATUS." >&2
      break
    fi
  fi
done

# --- Summary ----------------------------------------------------------------
# Written to stdout AND to a file, because the per-cell log directories are
# the only other record and nothing otherwise ties them together as one
# matrix run.
MATRIX_ELAPSED=$(( $(date -u +%s) - MATRIX_START ))
SUMMARY_FILE="$MATRIX_DIR/matrix-summary.md"

{
  echo "# FVR Matrix Run -- profile '${PROFILE}'"
  echo ""
  echo "- Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Run directory: \`$(basename "$MATRIX_DIR")\`"
  echo "- Cells run: ${#CELL_RESULTS[@]} of ${#COMBOS[@]} planned"
  echo "- Failures: ${FAILED_CELLS}"
  echo "- Total wall-clock: ${MATRIX_ELAPSED}s ($((MATRIX_ELAPSED / 60)) min)"
  echo ""
  echo "| Result | Cell | Elapsed | Directory | CI-STATUS |"
  echo "|--------|------|---------|-----------|-----------|"
  for r in "${CELL_RESULTS[@]}"; do
    IFS='|' read -r status label elapsed celldir cellstatus <<< "$r"
    echo "| $status | \`$label\` | $elapsed | \`$celldir/\` | $cellstatus |"
  done
  echo ""
  if [[ ${#CELL_RESULTS[@]} -lt ${#COMBOS[@]} ]]; then
    echo "> Stopped early after a failure; $(( ${#COMBOS[@]} - ${#CELL_RESULTS[@]} ))"
    echo "> planned cell(s) never ran. Re-run with --continue-on-failure to"
    echo "> execute every cell regardless of individual failures."
    echo ""
  fi
  echo "Each cell subdirectory above holds a complete, independent FVR run:"
  echo "its own test plan, report, timing/cost, and verified teardown. This"
  echo "file only indexes them."
  echo ""
  echo "**Read CI-STATUS, not just Result.** \`Result\` is the driver's exit"
  echo "code; \`CI-STATUS\` says what actually happened. A cell reading"
  echo "\`incomplete-no-report\` produced no report even though it exited"
  echo "cleanly."
} | tee "$SUMMARY_FILE"

echo ""
echo "[matrix] Summary written to: $SUMMARY_FILE"

[[ $FAILED_CELLS -eq 0 ]] || exit 1
exit 0
