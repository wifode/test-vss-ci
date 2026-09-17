#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Submit one Litmus hosted Skill Eval run and emit its id/URL.

Advisory: Litmus reviews are non-blocking per its own CI guidance (see
https://litmus.nvidia.com docs, "Use Litmus in CI"). This script never
raises to fail the job — every failure (missing token, network error, a
Litmus 4xx/5xx, quota exhaustion) is caught, surfaced as a `::warning`, and
the script still exits 0 with empty outputs so the workflow can skip the
comment row for this leg instead of failing the run.

Does not poll for completion — submitting holds a runner for one HTTP call;
polling would hold it for the eval's full minutes-to-hours run time. The
downstream PR comment links to the report URL instead.

Env:
    LITMUS_BASE_URL   Litmus host, e.g. https://litmus.nvidia.com
    LITMUS_API_TOKEN  bearer token (litmus_pat_...)
    SKILL_SOURCE      GitHub/GitLab URL to the skill (tree/<ref>/skills/<skill>)
    SKILL_NAME        skill_name to pass through to the eval
    EVAL_TYPE         knowledge | action | hybrid (default: hybrid)
    GITHUB_OUTPUT     optional; when set, key=value lines are appended here
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def emit_outputs(**kv: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            for key, value in kv.items():
                fh.write(f"{key}={value}\n")

    # Matrix job outputs don't aggregate across legs in GitHub Actions (a
    # downstream `needs:` job only sees the last-writer's outputs), so each
    # leg also drops a small result file that gets uploaded as an artifact.
    # The report job downloads every leg's artifact and merges them.
    result_dir = os.environ.get("RESULT_DIR", "").strip()
    skill = kv.get("skill", "")
    if result_dir and skill:
        Path(result_dir).mkdir(parents=True, exist_ok=True)
        (Path(result_dir) / f"{skill}.json").write_text(json.dumps(kv))


def main() -> int:
    base_url = (os.environ.get("LITMUS_BASE_URL") or "https://litmus.nvidia.com").rstrip("/")
    token = os.environ.get("LITMUS_API_TOKEN", "")
    skill_source = os.environ.get("SKILL_SOURCE", "")
    skill_name = os.environ.get("SKILL_NAME", "")
    eval_type = os.environ.get("EVAL_TYPE", "hybrid")

    # Emit empty outputs up front so a leg that fails before submitting still
    # produces well-formed (if empty) job outputs for the report job to skip.
    emit_outputs(run_id="", skill=skill_name, report_url="", submitted="false")

    if not token:
        print("::warning::LITMUS_API_TOKEN not set; skipping skill-eval submit "
              f"for {skill_name!r}", flush=True)
        return 0
    if not skill_source or not skill_name:
        print(f"::warning::missing SKILL_SOURCE/SKILL_NAME "
              f"(source={skill_source!r} name={skill_name!r}); skipping submit",
              flush=True)
        return 0

    payload = {
        "skill_source": skill_source,
        "skill_name": skill_name,
        "eval_type": eval_type,
    }
    req = urllib.request.Request(
        f"{base_url}/api/v1/skill-eval-agent/requests",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:200]
        print(f"::warning::Litmus submit failed for {skill_name!r} "
              f"({exc.code} {exc.reason}): {detail}", flush=True)
        return 0
    except Exception as exc:  # advisory: never fail the job
        print(f"::warning::Litmus submit failed for {skill_name!r}: {exc!r}",
              flush=True)
        return 0

    run_id = body.get("id", "")
    if not run_id:
        print(f"::warning::Litmus submit for {skill_name!r} returned no run id: "
              f"{body!r}", flush=True)
        return 0

    report_url = f"{base_url}/skill-eval-agent/{run_id}"
    print(f"::notice::Submitted Litmus skill-eval run {run_id} for "
          f"{skill_name!r} -> {report_url}", flush=True)
    emit_outputs(run_id=run_id, skill=skill_name, report_url=report_url,
                 submitted="true")
    return 0


if __name__ == "__main__":
    sys.exit(main())
