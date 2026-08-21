#!/usr/bin/env python3
"""Preflight gate for unattended VSS FVR runs (see AGENTS.md / CI plan).

Checks, before any agent work starts:
  1. Every env var that the selected VSS developer profile's own `.env`
     documents as REQUIRED (conditioned on the deploy mode) is actually set.
  2. The FVR pipeline's own fixed credential set is set.
  3. The SSH target is reachable and reports a GPU inventory.

Never resolves or prints secret values. Exits non-zero with every missing
var listed at once (not one at a time) on a hard failure. A GPU/hardware
mismatch against a requested pre-baked plan is NOT a hard failure here --
it's reported so the caller (scripts/ci/run-vss-fvr.sh) can fall back to
plan generation, per the CI plan's "pre-baked is a fast path, not a
requirement" design.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

# Vars whose .env comment explicitly says REQUIRED, and the substring of
# that comment's condition we match against the requested deploy mode.
# Extend this table if the VSS repo adds new REQUIRED-conditional vars --
# anything else matching the REQUIRED pattern is enforced conservatively
# (always required) rather than silently ignored.
KNOWN_CONDITIONAL_CREDENTIALS = {
    "NGC_CLI_API_KEY": {
        "condition": "local LLM / VLM deployment",
        # Required unless BOTH models are fully remote.
        "applies": lambda mode: mode.get("llm_mode") != "remote"
        or mode.get("vlm_mode") != "remote",
    },
    "NVIDIA_API_KEY": {
        "condition": "build.nvidia.com remote LLM / VLM endpoints",
        # Provider alone isn't enough -- a caller can pass --llm-provider
        # nvidia as a default hint even when llm_mode is local (see
        # scripts/ci/run-vss-fvr.sh's DEFAULT LLM_PROVIDER="nvidia"). Only
        # the corresponding model actually being in `remote` mode makes
        # this credential required.
        "applies": lambda mode: (
            mode.get("llm_mode") == "remote" and mode.get("llm_provider") == "nvidia"
        )
        or (mode.get("vlm_mode") == "remote" and mode.get("vlm_provider") == "nvidia"),
    },
    "OPENAI_API_KEY": {
        "condition": "openai remote LLM / VLM endpoints",
        "applies": lambda mode: (
            mode.get("llm_mode") == "remote" and mode.get("llm_provider") == "openai"
        )
        or (mode.get("vlm_mode") == "remote" and mode.get("vlm_provider") == "openai"),
    },
}

# Fixed vars the FVR pipeline itself always needs, regardless of profile.
FIXED_PIPELINE_VARS = ["SERVER_HOST", "SERVER_USER", "SSH_KEY_PATH", "ANTHROPIC_API_KEY"]

ENV_VAR_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def parse_dotenv_with_comments(path: Path) -> list[dict]:
    """Return [{name, value, comment, empty}] in file order, comment = the
    contiguous '#' block immediately preceding the var (blank line breaks it)."""
    entries = []
    comment_buf: list[str] = []
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            comment_buf = []
            continue
        if line.startswith("#"):
            comment_buf.append(line.lstrip("#").strip())
            continue
        m = ENV_VAR_RE.match(line)
        if not m:
            comment_buf = []
            continue
        name, value = m.group(1), m.group(2).strip()
        stripped_value = value.strip("'\"")
        entries.append(
            {
                "name": name,
                "value": value,
                "comment": " ".join(comment_buf),
                "empty": stripped_value == "" or stripped_value.startswith("${"),
            }
        )
        comment_buf = []
    return entries


def required_vars_for_profile(vss_repo: Path, profile: str, mode: dict) -> tuple[list[str], list[str]]:
    """Returns (required_names, info_only_names) for this profile/mode."""
    env_path = vss_repo / "deploy" / "docker" / "developer-profiles" / f"dev-profile-{profile}" / ".env"
    if not env_path.is_file():
        raise SystemExit(f"FATAL: no .env found for profile '{profile}' at {env_path}")

    required: list[str] = []
    info_only: list[str] = []
    for entry in parse_dotenv_with_comments(env_path):
        if not entry["empty"]:
            continue
        if "REQUIRED" not in entry["comment"].upper():
            # Explicitly Optional, or uncommented -- never enforced.
            info_only.append(entry["name"])
            continue
        known = KNOWN_CONDITIONAL_CREDENTIALS.get(entry["name"])
        if known is None:
            # A REQUIRED var we don't have a condition matcher for yet --
            # conservative default: always required, flagged for review.
            required.append(entry["name"])
            continue
        if known["applies"](mode):
            required.append(entry["name"])
        else:
            info_only.append(entry["name"])
    return required, info_only


def check_env_vars(names: list[str], env: dict) -> list[str]:
    missing = []
    for name in names:
        value = env.get(name, "")
        if not value or value.startswith("${"):
            missing.append(name)
    return missing


def ssh_gpu_inventory(
    server_host: str, server_user: str, ssh_key_path: str, attempts: int = 3, backoff: int = 20
) -> list[dict]:
    """Read the target's GPU inventory over SSH, retrying transient failures.

    Retries exist because a single SSH blip is not evidence the box is
    unusable: in a real matrix run, two consecutive cells died at preflight
    with `connect ... Operation timed out` while the box was in fact up the
    whole time and reachable again minutes later. A one-shot check turns a
    momentary network hiccup into a permanently-failed review, which is the
    worst possible trade when the alternative costs ~40 seconds.

    Only connection-level failures are retried. A box that answers and
    reports no GPUs, or rejects the key, is a real configuration problem --
    retrying that just wastes time and hides the actual error.
    """
    cmd = [
        "ssh",
        "-i",
        ssh_key_path,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=15",
        f"{server_user}@{server_host}",
        "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader",
    ]
    last_error = ""
    for attempt in range(1, attempts + 1):
        try:
            # Python-level timeout stays above the SSH-level ConnectTimeout as
            # a safety net (covers the remote command's own run time after
            # connect, not just the connection handshake) -- ConnectTimeout is
            # what makes a hung/unreachable box fail fast and cleanly instead
            # of relying solely on this outer kill.
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            last_error = (
                "SSH timed out (30s overall timeout exceeded even with a 15s "
                "SSH ConnectTimeout)"
            )
        else:
            if result.returncode == 0:
                break
            last_error = result.stderr.strip() or f"ssh exited {result.returncode}"

        if attempt < attempts:
            print(
                f"[preflight] SSH GPU check attempt {attempt}/{attempts} failed "
                f"({last_error}); retrying in {backoff}s...",
                file=sys.stderr,
            )
            time.sleep(backoff)
    else:
        raise SystemExit(
            f"FATAL: could not reach {server_host} or run nvidia-smi over SSH "
            f"after {attempts} attempts ({backoff}s apart).\n"
            f"last error: {last_error}\n"
            f"The box may be stopped/unreachable, the key or user may be wrong, "
            f"or the network path may be down for longer than this retry window."
        )

    gpus = []
    for line in result.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2:
            gpus.append({"name": parts[0], "memory_total": parts[1]})
    if not gpus:
        raise SystemExit(f"FATAL: nvidia-smi on {server_host} reported no GPUs")
    return gpus


def find_matching_plan(review_configs_dir: Path, profile: str, gpus: list[dict], mode: dict) -> Path | None:
    """Match a pre-baked review-configs/vss-<profile>-<hw>-<mode>.yaml by
    reading each candidate's server.gpu_type/gpu_count + mode fields.
    Lightweight YAML scan (grep-style) to avoid a hard PyYAML dependency."""
    detected_count = len(gpus)
    detected_type = gpus[0]["name"] if gpus else ""
    for candidate in sorted(review_configs_dir.glob(f"vss-{profile}-*.yaml")):
        text = candidate.read_text()
        gpu_type_m = re.search(r'gpu_type:\s*"?([^"\n]+)"?', text)
        gpu_count_m = re.search(r"gpu_count:\s*(\d+)", text)
        if not gpu_type_m or not gpu_count_m:
            continue
        plan_gpu_type = gpu_type_m.group(1).strip()
        plan_gpu_count = int(gpu_count_m.group(1))
        if plan_gpu_count != detected_count:
            continue
        if plan_gpu_type and plan_gpu_type.upper() not in detected_type.upper():
            continue
        llm_mode_m = re.search(r"LLM_MODE:\s*\"?(\w+)\"?", text)
        vlm_mode_m = re.search(r"VLM_MODE:\s*\"?(\w+)\"?", text)
        if llm_mode_m and mode.get("llm_mode") and llm_mode_m.group(1) != mode["llm_mode"]:
            continue
        if vlm_mode_m and mode.get("vlm_mode") and vlm_mode_m.group(1) != mode["vlm_mode"]:
            continue
        return candidate
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=["base", "alerts", "search", "lvs"])
    parser.add_argument("--vss-repo", required=True, type=Path)
    parser.add_argument("--review-configs-dir", required=True, type=Path)
    parser.add_argument(
        "--llm-mode", default="remote", choices=["local", "local_shared", "remote"]
    )
    parser.add_argument(
        "--vlm-mode", default="local", choices=["local", "local_shared", "remote"]
    )
    parser.add_argument("--llm-provider", default="", help="nvidia | openai | '' (n/a for local)")
    parser.add_argument("--vlm-provider", default="", help="nvidia | openai | '' (n/a for local)")
    parser.add_argument("--server-host", required=True)
    parser.add_argument("--server-user", required=True)
    parser.add_argument("--ssh-key-path", required=True)
    parser.add_argument("--env-json", required=True, help="path to a JSON object of CI env vars to check (never echoed)")
    parser.add_argument("--gdoc-enabled", action="store_true")
    parser.add_argument("--litmus-enabled", action="store_true")
    args = parser.parse_args()

    mode = {
        "llm_mode": args.llm_mode,
        "vlm_mode": args.vlm_mode,
        "llm_provider": args.llm_provider,
        "vlm_provider": args.vlm_provider,
    }

    ci_env = json.loads(Path(args.env_json).read_text())

    required, info_only = required_vars_for_profile(args.vss_repo, args.profile, mode)
    required += FIXED_PIPELINE_VARS
    if args.gdoc_enabled:
        required += ["GDRIVE_ACCESS_TOKEN"]
    if args.litmus_enabled:
        required += ["LITMUS_BASE_URL"]

    # server.* creds are supplied directly as CLI args, not looked up in
    # ci_env, but still folded into the same missing-list contract for a
    # single consistent failure report.
    missing = check_env_vars([v for v in required if v not in FIXED_PIPELINE_VARS], ci_env)
    for name, value in (
        ("SERVER_HOST", args.server_host),
        ("SERVER_USER", args.server_user),
        ("SSH_KEY_PATH", args.ssh_key_path),
    ):
        if not value:
            missing.append(name)
    if not ci_env.get("ANTHROPIC_API_KEY"):
        missing.append("ANTHROPIC_API_KEY")

    if missing:
        print("PREFLIGHT FAILED -- missing required credentials:", file=sys.stderr)
        for name in sorted(set(missing)):
            print(f"  - {name}", file=sys.stderr)
        print(
            f"\n(info-only vars left empty on purpose per the profile's own .env comments: "
            f"{', '.join(sorted(set(info_only))) or 'none'})",
            file=sys.stderr,
        )
        return 1

    gpus = ssh_gpu_inventory(args.server_host, args.server_user, args.ssh_key_path)
    matched_plan = find_matching_plan(args.review_configs_dir, args.profile, gpus, mode)

    result = {
        "status": "ok",
        "profile": args.profile,
        "mode": mode,
        "detected_gpus": gpus,
        "matched_plan": str(matched_plan) if matched_plan else None,
        "info_only_vars_left_empty": sorted(set(info_only)),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
