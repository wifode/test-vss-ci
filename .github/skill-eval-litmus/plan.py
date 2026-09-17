#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Compute the Litmus skills-eval dispatch matrix from a PR diff.

Sibling of .github/skill-eval/plan_matrix.py, but at skill-name granularity:
Litmus's hosted skill-eval-agent takes one (skill_source, skill_name) pair
per call, not a (spec, platform) matrix, so there is nothing to fan out per
spec here — just the set of skills touched by the PR.

Rules:
  - any tracked file under skills/<skill>/**  -> dispatch that skill
  - anything else (harness files, non-skill paths) -> contributes nothing

A harness-only diff (this directory, the workflow file, etc.) therefore
yields an empty matrix and the eval job is skipped, same convention as
plan_matrix.py.

Env:
    PR_BASE               base branch, e.g. develop (diffed as FETCH_HEAD...HEAD)
    MANUAL_SKILL          workflow_dispatch override: an explicit skill-dir
                           name — bypasses diffing entirely
    CHANGED_FILES         optional newline-separated override (tests / local)
    GITHUB_OUTPUT          optional; when set, key=value lines are appended here
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# .github/skill-eval-litmus/plan.py -> parents[2] = repo root
REPO_ROOT = Path(__file__).resolve().parents[2]

SKILL_FILE_RE = re.compile(r"^skills/([^/]+)/")
SAFE_SKILL_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def list_changed_files() -> list[str]:
    """Changed files in the cumulative PR diff (base...mirror head).

    See plan_matrix.list_changed_files for why this uses a local `git diff`
    rather than the GitHub compare API (300-file cap).
    """
    override = os.environ.get("CHANGED_FILES")
    if override is not None:
        return [ln.strip() for ln in override.splitlines() if ln.strip()]

    base = os.environ["PR_BASE"]
    subprocess.run(
        ["git", "-C", str(REPO_ROOT), "fetch", "--no-tags", "--quiet",
         "origin", base],
        check=True,
    )
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "diff", "--name-only", "FETCH_HEAD...HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [ln.strip() for ln in out.splitlines() if ln.strip()]


def build_matrix(changed: list[str]) -> list[dict]:
    skills: set[str] = set()
    for f in changed:
        m = SKILL_FILE_RE.match(f)
        if m:
            skills.add(m.group(1))
    return [{"skill": skill} for skill in sorted(skills)]


def emit(include: list[dict]) -> None:
    for leg in include:
        if not SAFE_SKILL_RE.match(leg["skill"]):
            raise ValueError(
                f"unsafe skill name {leg['skill']!r}: expected "
                f"[A-Za-z0-9_-] (used to build the skill_source URL and the "
                f"job matrix)"
            )

    matrix = json.dumps({"include": include}, separators=(",", ":"))
    has_targets = "true" if include else "false"

    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"matrix={matrix}\n")
            fh.write(f"has_targets={has_targets}\n")

    print(f"has_targets={has_targets}")
    print(f"skills={len(include)}")
    for leg in include:
        print(f"  - {leg['skill']}")
    print(f"matrix={matrix}")


def main() -> int:
    manual = os.environ.get("MANUAL_SKILL", "").strip()
    if manual:
        if not SAFE_SKILL_RE.match(manual):
            raise ValueError(
                f"unsafe MANUAL_SKILL {manual!r}: expected a skill-dir name "
                f"([A-Za-z0-9_-])"
            )
        changed = [f"skills/{manual}/SKILL.md"]
    else:
        changed = list_changed_files()

    print(f"changed files ({len(changed)}):", file=sys.stderr)
    for f in changed:
        print(f"  {f}", file=sys.stderr)
    emit(build_matrix(changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
