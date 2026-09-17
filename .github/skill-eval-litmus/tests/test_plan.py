#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for plan.build_matrix — the diff -> changed-skill-set rules.

Run:
    python3 -m pytest .github/skill-eval-litmus/tests/test_plan.py -v
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "plan", Path(__file__).resolve().parents[1] / "plan.py"
)
plan = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(plan)


class BuildMatrix(unittest.TestCase):
    def test_single_skill_changed(self):
        changed = ["skills/vss-ask-video/SKILL.md"]
        self.assertEqual(plan.build_matrix(changed), [{"skill": "vss-ask-video"}])

    def test_multiple_skills_changed_deduped_and_sorted(self):
        changed = [
            "skills/vss-summarize-video/evals/a.json",
            "skills/vss-summarize-video/references/notes.md",
            "skills/vss-ask-video/SKILL.md",
        ]
        self.assertEqual(
            plan.build_matrix(changed),
            [{"skill": "vss-ask-video"}, {"skill": "vss-summarize-video"}],
        )

    def test_harness_only_diff_yields_empty_matrix(self):
        changed = [
            ".github/skill-eval-litmus/plan.py",
            ".github/workflows/skills-eval-litmus.yml",
            "README.md",
        ]
        self.assertEqual(plan.build_matrix(changed), [])

    def test_non_skill_paths_ignored(self):
        changed = ["docs/overview.md", ".github/skill-eval/AGENTS.md"]
        self.assertEqual(plan.build_matrix(changed), [])

    def test_no_changes(self):
        self.assertEqual(plan.build_matrix([]), [])


class Emit(unittest.TestCase):
    def test_rejects_unsafe_skill_name(self):
        with self.assertRaises(ValueError):
            plan.emit([{"skill": "vss/evil path"}])

    def test_accepts_safe_skill_names(self):
        plan.emit([{"skill": "vss-ask-video"}])   # no raise


if __name__ == "__main__":
    unittest.main()
