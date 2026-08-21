#!/usr/bin/env python3
"""Report-integrity gate for unattended FVR runs (see ci/CI_OVERRIDE.md).

An interactive FVR has a human at Step 8 who reads the report next to the
run's own artifacts and says "you dropped three things your own quality
reviewer flagged." An unattended run has nobody there, and a side-by-side
against a human-grounded report of the same product found exactly that
failure mode: the CI report's *evidence* was sound, but its *self-limiting
discipline* had slipped -- gaps went undisclosed, a single bug with two
downstream effects was promoted to a "pattern," and a skipped pipeline step
vanished from the report entirely instead of being named.

This script is the mechanical half of that missing gate. It checks:
  1. Scope Limits disclosure -- the quality review's untested/unaddressed
     in-scope list is reflected in a Scope Limits (or equivalently-named)
     section of the report.
  2. Top Issues are patterns -- each cites >= 2 *independent* examples.
     "One root cause, two visible symptoms" is one example, not two.
  3. Skipped/blocked steps are disclosed -- any artifact carrying a
     SKIPPED/BLOCKED status marker is named somewhere in the report.
  4. Thin-evidence rows are hedged (advisory) -- a rated heat-map row whose
     summary cell carries no number and no citation at all.

It is deliberately generic: no product, GPU, host, profile or doc URL is
hardcoded, and every artifact is optional. A missing artifact SKIPS its
check with a stated reason rather than crashing or failing the run.

It is also deliberately approximate where exactness is not achievable.
Item-for-item matching between two differently-worded prose lists is not a
solvable string problem, so check 1 compares counts and says so; check 4 is
WARN-only. Only checks 1 (no section at all), 2 and 3 can FAIL, because
those are the three failure modes where a report actively reads as more
complete than the run was.

Exit codes: 0 = all PASS/WARN/SKIPPED, 1 = at least one FAIL (or any WARN
under --strict), 2 = usage / IO error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Tunables. Every threshold that encodes a judgment call lives here.
# --------------------------------------------------------------------------

# Check 1: fraction of the quality review's flagged gaps the report must
# appear to disclose before we stop warning. Deliberately below 1.0 -- the
# two lists are counted from differently-shaped sources (a QA table row is
# not one-to-one with a report bullet), so demanding parity would warn on
# every well-behaved report.
SCOPE_DISCLOSURE_RATIO = 0.6

# Check 2: AGENTS.md's own bar for a Top Issue.
MIN_INDEPENDENT_EXAMPLES = 2

# Check 3: share of a step's topic terms that must appear in the report
# before we call the step "mentioned".
TOPIC_MENTION_RATIO = 0.5

# Report filenames tried in order when --report is not given.
DEFAULT_REPORT_NAMES = ("07-grounded-report.md", "06-final-report.md")

# --------------------------------------------------------------------------
# Generic markdown helpers
# --------------------------------------------------------------------------

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
TABLE_SEP_RE = re.compile(r"^\|[\s:|-]+\|?$")
LIST_ITEM_RE = re.compile(r"^\s{0,3}(?:[-*+]|\d+[.)])\s+\S")
NUMBERED_ITEM_RE = re.compile(r"^\s{0,3}(\d+)[.)]\s+(\S.*)$")
HRULE_RE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")

# An evidence anchor: an artifact filename, optionally followed by line
# references. Matches `02-commands.jsonl L48`, "03-test-results.md L79, L154",
# `04-perf-results.md` L15-25, quickstart.html, screenshots/foo.png.
ARTIFACT_RE = re.compile(
    r"`?([A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:md|jsonl|json|ya?ml|log|txt|csv|png|jpg|html|htm))`?"
    r"((?:[\s,;]*L?\d+(?:\s*[-–—]\s*L?\d+)?)*)",
    re.IGNORECASE,
)
LINEREF_RE = re.compile(r"L?(\d+)(?:\s*[-–—]\s*L?(\d+))?")

RATING_VALUES = {"good", "fair", "needs improvement", "poor"}


def strip_markup(text: str) -> str:
    """Drop the decoration that varies between report-writing styles."""
    text = re.sub(r"<br\s*/?>", " ", text, flags=re.IGNORECASE)
    text = text.replace("**", "").replace("`", "")
    return text.strip()


def iter_headings(lines: list[str]):
    """Yield (index, level, title) for every ATX heading."""
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if m:
            yield i, len(m.group(1)), strip_markup(m.group(2))


def heading_body(lines: list[str], start: int, level: int) -> list[str]:
    """Lines under the heading at `start`, up to the next heading of
    equal-or-higher rank (or EOF)."""
    body = []
    for i in range(start + 1, len(lines)):
        m = HEADING_RE.match(lines[i])
        if m and len(m.group(1)) <= level:
            break
        body.append(lines[i])
    return body


def count_items(block: list[str]) -> int:
    """Count discrete items in a block, whichever way the author wrote them:
    table data rows or list items. Takes the larger of the two so a section
    with a table plus an explanatory bullet list is not double-counted."""
    table_rows = 0
    list_items = 0
    for line in block:
        stripped = line.strip()
        if stripped.startswith("|") and stripped.count("|") >= 2:
            if TABLE_SEP_RE.match(stripped):
                # The header row above was counted as data; take it back.
                table_rows -= 1
                continue
            table_rows += 1
        elif LIST_ITEM_RE.match(line):
            list_items += 1
    return max(max(table_rows, 0), list_items)


def evidence_anchors(text: str) -> tuple[set[str], set[str]]:
    """Return (distinct anchors, distinct artifact files) cited in `text`.

    An anchor is an artifact plus a specific line reference where one is
    given (`03-test-results.md:79`), or the bare artifact otherwise. Two
    citations of the same file at the same line are one anchor.
    """
    anchors: set[str] = set()
    files: set[str] = set()
    for m in ARTIFACT_RE.finditer(text):
        fname = m.group(1).lower()
        files.add(fname)
        refs = m.group(2) or ""
        found = False
        for lm in LINEREF_RE.finditer(refs):
            anchors.add(f"{fname}:{lm.group(1)}")
            found = True
        if not found:
            anchors.add(fname)
    return anchors, files


# --------------------------------------------------------------------------
# Result plumbing
# --------------------------------------------------------------------------

PASS, WARN, FAIL, SKIPPED = "PASS", "WARN", "FAIL", "SKIPPED"


class Check:
    def __init__(self, key: str, title: str):
        self.key = key
        self.title = title
        self.status = SKIPPED
        self.summary = ""
        self.details: list[str] = []
        self.data: dict = {}

    def set(self, status: str, summary: str) -> None:
        self.status = status
        self.summary = summary

    def to_dict(self) -> dict:
        return {
            "check": self.key,
            "title": self.title,
            "status": self.status,
            "summary": self.summary,
            "details": self.details,
            "data": self.data,
        }


# --------------------------------------------------------------------------
# Check 1 -- Scope Limits disclosure
# --------------------------------------------------------------------------

# Headings in a quality review that introduce untested / unaddressed items.
GAP_HEADING_RE = re.compile(
    r"(untested|unaddressed|not\s+(?:executed|tested|run|covered|attempted)|"
    r"coverage\s+gaps?|gaps?\s+found|open\s+gaps?|missing\s+coverage|action\s+required)",
    re.IGNORECASE,
)
# ... but not the sections that exist precisely to say "this was fine".
GAP_HEADING_EXCLUDE_RE = re.compile(
    r"(acceptable|not\s+a\s+gap|non-coverage|correctly[\s-]scoped|"
    r"recorded\s+reason|(?<!not\s)waived)",
    re.IGNORECASE,
)

# Section names in a report that count as a Scope Limits disclosure.
SCOPE_SECTION_RE = re.compile(
    r"^(scope\s+limit|scope\s+limitation|coverage\s+limit|coverage\s+gap|"
    r"testing\s+limitation|known\s+limitation|limitations?\b|not\s+tested|"
    r"untested|what\s+was\s+not\s+tested|out\s+of\s+scope|known\s+gaps?)",
    re.IGNORECASE,
)
# The same disclosure written inline in a heat-map cell or bullet.
INLINE_SCOPE_RE = re.compile(
    r"\*\*\s*(?:scope\s+limits?|coverage\s+limits?|not\s+tested|untested|"
    r"scope\s+limitation)\s*:?\s*\*\*",
    re.IGNORECASE,
)


def find_gap_sections(qr_lines: list[str]) -> list[tuple[str, int]]:
    """(heading title, item count) for each untested/unaddressed section."""
    out = []
    for idx, level, title in iter_headings(qr_lines):
        if not GAP_HEADING_RE.search(title):
            continue
        if GAP_HEADING_EXCLUDE_RE.search(title):
            continue
        n = count_items(heading_body(qr_lines, idx, level))
        out.append((title, n))
    return out


def find_scope_sections(rep_lines: list[str]) -> list[tuple[str, int]]:
    """(marker text, item count) for each Scope Limits section in a report.

    Handles both a real markdown heading and the plain `Scope Limits:` lead-in
    line that several report styles use instead.
    """
    out = []
    heading_idxs = set()
    for idx, level, title in iter_headings(rep_lines):
        if SCOPE_SECTION_RE.match(title):
            heading_idxs.add(idx)
            out.append((title, count_items(heading_body(rep_lines, idx, level))))

    for i, line in enumerate(rep_lines):
        if i in heading_idxs:
            continue
        stripped = strip_markup(line)
        if not stripped or len(stripped) > 140:
            continue
        if line.lstrip().startswith(("|", ">", "-", "*", "+")):
            continue  # a cell or bullet, not a section lead-in
        if not SCOPE_SECTION_RE.match(stripped):
            continue
        # Consume the list that follows, allowing blank lines inside it.
        n, j, seen_item = 0, i + 1, False
        while j < len(rep_lines):
            nxt = rep_lines[j]
            if not nxt.strip():
                j += 1
                continue
            if HEADING_RE.match(nxt) or HRULE_RE.match(nxt):
                break
            if LIST_ITEM_RE.match(nxt) or nxt.strip().startswith("|"):
                if LIST_ITEM_RE.match(nxt):
                    n += 1
                seen_item = True
                j += 1
                continue
            if seen_item:
                break
            j += 1
        if n:
            out.append((stripped, n))
    return out


def check_scope_limits(check: Check, qr_text: str | None, rep_text: str | None) -> None:
    if qr_text is None:
        check.set(SKIPPED, "quality review artifact not present -- nothing to compare against")
        return
    if rep_text is None:
        check.set(SKIPPED, "report artifact not present")
        return

    gap_sections = find_gap_sections(qr_text.splitlines())
    gaps = sum(n for _, n in gap_sections)
    scope_sections = find_scope_sections(rep_text.splitlines())
    section_items = sum(n for _, n in scope_sections)
    inline = len(INLINE_SCOPE_RE.findall(rep_text))
    disclosed = section_items + inline

    check.data = {
        "gaps_flagged": gaps,
        "gap_sections": [{"heading": t, "items": n} for t, n in gap_sections],
        "scope_sections": [{"marker": t, "items": n} for t, n in scope_sections],
        "inline_scope_markers": inline,
        "items_disclosed": disclosed,
        "comparison": "approximate (item counts, not item-for-item matching)",
    }
    for title, n in gap_sections:
        check.details.append(f"quality review: {n} item(s) under {title!r}")
    for title, n in scope_sections:
        check.details.append(f"report: {n} item(s) under {title!r}")
    if inline:
        check.details.append(f"report: {inline} inline scope-limit marker(s) (e.g. '**Scope limit:**')")
    check.details.append(
        "Counts are compared approximately -- differently-worded lists cannot be "
        "matched item-for-item, so this is a disclosure-volume signal, not proof "
        "that each specific gap was carried across."
    )

    if gaps == 0:
        check.set(
            SKIPPED,
            "quality review flagged no untested/unaddressed in-scope items "
            f"(searched {len(gap_sections)} candidate section(s)) -- nothing to disclose",
        )
        return
    if disclosed == 0:
        check.set(
            FAIL,
            f"quality review flagged {gaps} gap(s) but the report has no Scope Limits "
            "(or equivalently-named) section and no inline scope-limit disclosures",
        )
        return
    threshold = max(1, int(gaps * SCOPE_DISCLOSURE_RATIO + 0.999))
    if disclosed < threshold:
        check.set(
            WARN,
            f"report discloses ~{disclosed} item(s) against {gaps} gap(s) flagged by the "
            f"quality review (below the {SCOPE_DISCLOSURE_RATIO:.0%} disclosure threshold "
            f"of {threshold})",
        )
        return
    check.set(
        PASS,
        f"report discloses ~{disclosed} item(s) against {gaps} gap(s) flagged by the "
        "quality review",
    )


# --------------------------------------------------------------------------
# Check 2 -- Top Issues are patterns
# --------------------------------------------------------------------------

TOP_ISSUES_MARKER_RE = re.compile(r"^\s*(?:#{1,6}\s*)?(?:\*\*)?top\s+issues", re.IGNORECASE)

# "one root cause, two visible symptoms" and its relatives. Detected as a
# co-occurrence inside one sentence rather than as a fixed phrase, so it
# survives rewording.
SINGULAR_CAUSE_RE = re.compile(
    r"\b(?:one|single|same|identical|a\s+single|the\s+same)\s+(?:\w+[\s-]){0,3}"
    r"(?:root\s+cause|cause|bug|defect|misconfiguration|configuration|config|"
    r"issue|mistake|change|fix|setting|hostname|value|line|default|flag|"
    r"parameter|variable|endpoint|typo|regression|commit|file)\b"
    r"|\bsame\s+root\s+cause\b|\bconsolidated\b|\bone\s+and\s+the\s+same\b",
    re.IGNORECASE,
)
MULTI_SYMPTOM_RE = re.compile(
    r"\b(?:two|three|four|both|multiple|several)\s+(?:\w+[\s-]){0,2}"
    r"(?:symptoms?|manifestations?|effects?|surfaces?|faces?)\b"
    r"|\bdownstream\s+(?:effects?|symptoms?|consequences?)\b"
    r"|\bsymptom\s*[12]\b",
    re.IGNORECASE,
)
# The "one <anything>, N symptoms" shape. Weaker on the cause side, so it is
# only trusted when the sentence literally says "symptom(s)" -- that word is
# rare enough in a Top Issue that a false positive is unlikely, while the
# noun on the cause side is unbounded ("one misconfigured default").
BARE_SINGULAR_RE = re.compile(r"\b(?:one|single|a\s+single|the\s+same|same)\b", re.IGNORECASE)
EXPLICIT_SYMPTOM_RE = re.compile(
    r"\b(?:two|three|four|both|multiple|several)\s+(?:\w+[\s-]){0,2}symptoms?\b"
    r"|\bsymptom\s*[12]\b",
    re.IGNORECASE,
)
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?;])\s+|\s+[-–—]{1,2}\s+")


def find_top_issues(rep_lines: list[str]) -> list[tuple[str, str]]:
    """[(label, text)] for each Top Issue, in document order."""
    marker = None
    for i, line in enumerate(rep_lines):
        if TOP_ISSUES_MARKER_RE.match(line):
            marker = i
            break
    if marker is None:
        return []

    issues: list[tuple[str, list[str]]] = []
    current: list[str] | None = None
    label = ""
    prev_blank = False
    for line in rep_lines[marker + 1 :]:
        if HEADING_RE.match(line) or HRULE_RE.match(line):
            break
        m = NUMBERED_ITEM_RE.match(line)
        if m:
            if current is not None:
                issues.append((label, current))
            label = m.group(1)
            current = [m.group(2)]
            prev_blank = False
            continue
        if not line.strip():
            prev_blank = True
            continue
        if current is None:
            prev_blank = False
            continue
        # A fresh, unindented, non-numbered line after a blank line has left
        # the list (e.g. "Quick Stats"). Anything else continues the item.
        if prev_blank and not line.startswith((" ", "\t", "|", ">")):
            break
        current.append(line)
        prev_blank = False
    if current is not None:
        issues.append((label, current))

    if issues:
        return [(lbl, "\n".join(body)) for lbl, body in issues]

    # Fallback: some styles use subheadings under a "Top Issues" heading.
    for idx, level, title in iter_headings(rep_lines):
        if TOP_ISSUES_MARKER_RE.match(title):
            body = heading_body(rep_lines, idx, level)
            out, cur, cur_title = [], None, ""
            for line in body:
                m = HEADING_RE.match(line)
                if m:
                    if cur is not None:
                        out.append((cur_title, "\n".join(cur)))
                    cur_title, cur = strip_markup(m.group(2)), []
                    continue
                if cur is not None:
                    cur.append(line)
            if cur is not None:
                out.append((cur_title, "\n".join(cur)))
            return out
    return []


def issue_title(text: str) -> str:
    first = strip_markup(text.splitlines()[0]) if text.strip() else ""
    first = re.sub(r"\s+", " ", first)
    return (first[:90] + "...") if len(first) > 90 else first


def self_admits_single_example(text: str) -> str | None:
    """Return the offending sentence when an issue describes itself as one
    root cause with several symptoms -- that is one example, not two."""
    flat = re.sub(r"\s+", " ", strip_markup(text))
    for sentence in SENTENCE_SPLIT_RE.split(flat):
        if SINGULAR_CAUSE_RE.search(sentence) and MULTI_SYMPTOM_RE.search(sentence):
            return sentence.strip()
        if BARE_SINGULAR_RE.search(sentence) and EXPLICIT_SYMPTOM_RE.search(sentence):
            return sentence.strip()
    return None


def check_top_issues(check: Check, rep_text: str | None) -> None:
    if rep_text is None:
        check.set(SKIPPED, "report artifact not present")
        return
    issues = find_top_issues(rep_text.splitlines())
    if not issues:
        check.set(SKIPPED, "no Top Issues section found in the report")
        return

    per_issue = []
    failures = 0
    for label, text in issues:
        anchors, files = evidence_anchors(text)
        admission = self_admits_single_example(text)
        status = PASS
        reason = ""
        if admission:
            status = FAIL
            reason = (
                "self-described as one root cause with multiple symptoms "
                f"-- that is 1 example, not {len(anchors)}: {admission!r}"
            )
        elif len(anchors) < MIN_INDEPENDENT_EXAMPLES:
            status = FAIL
            reason = (
                f"cites {len(anchors)} independent evidence reference(s), "
                f"below the {MIN_INDEPENDENT_EXAMPLES}-example pattern bar"
            )
        if status == FAIL:
            failures += 1
        per_issue.append(
            {
                "issue": label,
                "title": issue_title(text),
                "independent_examples_estimate": len(anchors),
                "distinct_artifacts_cited": len(files),
                "self_admitted_single_cause": admission,
                "status": status,
                "reason": reason,
            }
        )
        marker = "OK " if status == PASS else "FAIL"
        check.details.append(
            f"[{marker}] Issue {label}: ~{len(anchors)} independent example(s) "
            f"across {len(files)} artifact(s) -- {issue_title(text)}"
        )
        if reason:
            check.details.append(f"         reason: {reason}")

    check.data = {"issues": per_issue, "issues_found": len(issues), "failing": failures}
    if failures:
        check.set(
            FAIL,
            f"{failures} of {len(issues)} Top Issue(s) do not meet the "
            f"{MIN_INDEPENDENT_EXAMPLES}-independent-example pattern bar",
        )
    else:
        check.set(
            PASS,
            f"all {len(issues)} Top Issue(s) cite >= {MIN_INDEPENDENT_EXAMPLES} "
            "independent examples",
        )


# --------------------------------------------------------------------------
# Check 3 -- skipped / blocked steps disclosed
# --------------------------------------------------------------------------

STATUS_LINE_RE = re.compile(
    r"^[^\S\n]{0,3}(?:#{1,6}[^\S\n]*)?(?:[-*+][^\S\n]*)?(?:\*\*)?status(?:\*\*)?"
    r"[^\S\n]*[:\-–—][^\S\n]*(?:\*\*)?[^\S\n]*(skipped|blocked|not[^\S\n]*run|skip)\b",
    re.IGNORECASE | re.MULTILINE,
)
STATUS_HEADING_RE = re.compile(
    r"^\s{0,3}#{1,6}\s+.*?[\s\-–—:]+(SKIPPED|BLOCKED|NOT\s+RUN)\s*$",
    re.MULTILINE,
)
STATUS_FIELD_RE = re.compile(
    r"^\s*(?:[-*+]\s*)?\*\*(skipped|blocked)\s*:?\*\*\s*:?\s*(?:yes|true)\b",
    re.IGNORECASE | re.MULTILINE,
)

TOPIC_STOPWORDS = {
    "results", "result", "review", "reviews", "report", "reports", "final",
    "log", "logs", "output", "outputs", "test", "tests", "testing", "run",
    "config", "inputs", "user", "grounded", "commands", "doc", "docs",
}


def topic_terms(path: Path, text: str) -> list[str]:
    stem = re.sub(r"^\d+[a-z]?[-_]", "", path.stem)
    tokens = [t for t in re.split(r"[-_\s]+", stem) if t]
    terms = [t for t in tokens if t.lower() not in TOPIC_STOPWORDS and len(t) >= 2]
    if not terms:
        # Fall back to the artifact's own title line.
        for line in text.splitlines():
            m = HEADING_RE.match(line)
            if m:
                title = strip_markup(m.group(2))
                title = re.split(r"[—\-:]", title)[0]
                terms = [
                    t
                    for t in re.split(r"[^A-Za-z0-9]+", title)
                    if t and t.lower() not in TOPIC_STOPWORDS and len(t) >= 2
                ]
                break
    return terms


def check_skipped_disclosed(check: Check, log_dir: Path, report_path: Path | None,
                            rep_text: str | None) -> None:
    if rep_text is None:
        check.set(SKIPPED, "report artifact not present")
        return

    rep_lower = rep_text.lower()
    found = []
    for path in sorted(log_dir.glob("*.md")):
        if report_path is not None and path.resolve() == report_path.resolve():
            continue
        if re.search(r"(grounded|final).*report", path.name, re.IGNORECASE):
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        markers = []
        for rx, kind in (
            (STATUS_LINE_RE, "status line"),
            (STATUS_HEADING_RE, "heading"),
            (STATUS_FIELD_RE, "status field"),
        ):
            m = rx.search(text)
            if m:
                markers.append(f"{kind}: {m.group(0).strip()[:80]}")
        if not markers:
            continue
        terms = topic_terms(path, text)
        present = [
            t for t in terms
            if re.search(r"\b" + re.escape(t.lower()) + r"\b", rep_lower)
        ]
        ratio = (len(present) / len(terms)) if terms else 0.0
        mentioned = bool(present) and ratio >= TOPIC_MENTION_RATIO
        found.append(
            {
                "artifact": path.name,
                "markers": markers,
                "topic_terms": terms,
                "terms_found_in_report": present,
                "mentioned_in_report": mentioned,
            }
        )

    check.data = {"skipped_or_blocked_artifacts": found}
    if not found:
        check.set(SKIPPED, "no artifact in the log directory carries a SKIPPED/BLOCKED status marker")
        return

    undisclosed = [f for f in found if not f["mentioned_in_report"]]
    for f in found:
        mark = "OK " if f["mentioned_in_report"] else "FAIL"
        check.details.append(
            f"[{mark}] {f['artifact']} -- {f['markers'][0]}; searched report for "
            f"{f['topic_terms']}, found {f['terms_found_in_report'] or 'nothing'}"
        )
    if undisclosed:
        names = ", ".join(f["artifact"] for f in undisclosed)
        check.set(
            FAIL,
            f"{len(undisclosed)} of {len(found)} skipped/blocked step(s) are never "
            f"mentioned in the report ({names})",
        )
    else:
        check.set(PASS, f"all {len(found)} skipped/blocked step(s) are mentioned in the report")


# --------------------------------------------------------------------------
# Check 4 -- thin-evidence rows hedged (advisory, WARN-only)
# --------------------------------------------------------------------------

SAMPLE_SIZE_RE = re.compile(
    r"\bn\s*=\s*\d+|\bsingle[- ](?:sample|measurement|shot|run|data\s+point)\b|"
    r"\b\d+\s*(?:samples?|runs?|iterations?|measurements?|attempts?|times)\b|"
    r"\b\d+\s*/\s*\d+\b|\bp\d{2}\b|\bmean\b|\bmedian\b",
    re.IGNORECASE,
)


def parse_tables(lines: list[str]) -> list[list[list[str]]]:
    """Return each markdown table as a list of rows of cells."""
    tables, current = [], []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("|") and stripped.count("|") >= 2:
            current.append([c.strip() for c in stripped.strip("|").split("|")])
        else:
            if len(current) >= 2:
                tables.append(current)
            current = []
    if len(current) >= 2:
        tables.append(current)
    return tables


def check_thin_evidence(check: Check, rep_text: str | None) -> None:
    check.details.append(
        "ADVISORY ONLY -- this heuristic never fails the gate. It flags a rated "
        "row whose summary cell carries no citation at all AND states no sample "
        "size. A bare digit is not treated as evidence: 'exit-code-0' is a name, "
        "not a measurement."
    )
    if rep_text is None:
        check.set(SKIPPED, "report artifact not present")
        return

    flagged, rated_rows = [], 0
    for table in parse_tables(rep_text.splitlines()):
        header = [strip_markup(c).lower() for c in table[0]]
        body = [r for r in table[1:] if not TABLE_SEP_RE.match("|" + "|".join(r) + "|")]
        rating_col = next((i for i, h in enumerate(header) if "rating" in h), None)
        if rating_col is None:
            continue
        summary_col = next(
            (i for i, h in enumerate(header) if h in ("summary", "notes", "comment", "comments")),
            None,
        )
        for row in body:
            if rating_col >= len(row):
                continue
            rating = strip_markup(row[rating_col]).lower()
            if rating not in RATING_VALUES:
                continue
            rated_rows += 1
            if summary_col is not None and summary_col < len(row):
                summary = row[summary_col]
            else:  # widest cell that is not the rating cell
                candidates = [(len(c), i) for i, c in enumerate(row) if i != rating_col]
                summary = row[max(candidates)[1]] if candidates else ""
            label = strip_markup(row[0])[:60] if row else "?"
            anchors, _ = evidence_anchors(summary)
            has_citation = bool(anchors) or "verify" in summary.lower() or "http" in summary.lower()
            has_sample_size = bool(SAMPLE_SIZE_RE.search(summary))
            has_number = bool(re.search(r"\d", strip_markup(summary)))
            if not has_citation and not has_sample_size:
                flagged.append(
                    {
                        "row": label,
                        "rating": strip_markup(row[rating_col]),
                        "reason": "summary cell cites no artifact and states no sample size"
                        + (" (it does contain digits, but none read as a measurement)"
                           if has_number else " and contains no numbers"),
                        "states_sample_size": has_sample_size,
                        "has_citation": has_citation,
                    }
                )

    check.data = {"rated_rows": rated_rows, "flagged_rows": flagged}
    if rated_rows == 0:
        check.set(SKIPPED, "no rated heat-map/ratings table found in the report")
        return
    for f in flagged:
        check.details.append(f"[WARN] row {f['row']!r} ({f['rating']}): {f['reason']}")
    if flagged:
        check.set(
            WARN,
            f"{len(flagged)} of {rated_rows} rated row(s) cite nothing and state no "
            "sample size (advisory)",
        )
    else:
        check.set(PASS, f"all {rated_rows} rated row(s) carry a citation or a stated sample size")


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def resolve_report(log_dir: Path, explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit if explicit.is_file() else None
    for name in DEFAULT_REPORT_NAMES:
        candidate = log_dir / name
        if candidate.is_file():
            return candidate
    return None


def read_optional(path: Path | None) -> str | None:
    if path is None or not path.is_file():
        return None
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def find_quality_review(log_dir: Path) -> Path | None:
    exact = log_dir / "05-quality-review.md"
    if exact.is_file():
        return exact
    matches = sorted(log_dir.glob("*quality*review*.md"))
    return matches[0] if matches else None


STATUS_ORDER = {FAIL: 0, WARN: 1, SKIPPED: 2, PASS: 3}


def human_output(checks: list[Check], meta: dict, stream) -> None:
    print("=" * 74, file=stream)
    print("FVR REPORT INTEGRITY CHECK", file=stream)
    print("=" * 74, file=stream)
    print(f"Log directory : {meta['log_dir']}", file=stream)
    print(f"Report        : {meta['report'] or '(none found)'}", file=stream)
    print(f"Quality review: {meta['quality_review'] or '(none found)'}", file=stream)
    for check in checks:
        print("", file=stream)
        print(f"--- {check.title}", file=stream)
        print(f"    {check.status}: {check.summary}", file=stream)
        for line in check.details:
            print(f"      {line}", file=stream)
    counts = {s: sum(1 for c in checks if c.status == s) for s in (PASS, WARN, FAIL, SKIPPED)}
    print("", file=stream)
    print("-" * 74, file=stream)
    print(
        f"RESULT: {counts[FAIL]} FAIL, {counts[WARN]} WARN, "
        f"{counts[PASS]} PASS, {counts[SKIPPED]} SKIPPED  ->  exit {meta['exit_code']}",
        file=stream,
    )
    print("-" * 74, file=stream)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log-dir", required=True, type=Path,
                        help="the FVR run's log directory (logs/<product>-<date>/)")
    parser.add_argument("--report", type=Path, default=None,
                        help="report file to check (default: 07-grounded-report.md, "
                             "else 06-final-report.md, inside --log-dir)")
    parser.add_argument("--json", action="store_true",
                        help="emit machine-readable JSON on stdout (human output goes to stderr)")
    parser.add_argument("--strict", action="store_true",
                        help="treat WARN as a failure (exit 1)")
    args = parser.parse_args()

    log_dir: Path = args.log_dir
    if not log_dir.is_dir():
        print(f"ERROR: --log-dir is not a directory: {log_dir}", file=sys.stderr)
        return 2
    if args.report is not None and not args.report.is_file():
        print(f"ERROR: --report is not a file: {args.report}", file=sys.stderr)
        return 2

    report_path = resolve_report(log_dir, args.report)
    rep_text = read_optional(report_path)
    qr_path = find_quality_review(log_dir)
    qr_text = read_optional(qr_path)

    checks = [
        Check("scope_limits", "1. Scope Limits disclosure"),
        Check("top_issues_are_patterns", "2. Top Issues are patterns (2+ independent examples)"),
        Check("skipped_steps_disclosed", "3. Skipped/blocked steps disclosed"),
        Check("thin_evidence_rows", "4. Thin-evidence rows hedged (advisory)"),
    ]
    check_scope_limits(checks[0], qr_text, rep_text)
    check_top_issues(checks[1], rep_text)
    check_skipped_disclosed(checks[2], log_dir, report_path, rep_text)
    check_thin_evidence(checks[3], rep_text)

    has_fail = any(c.status == FAIL for c in checks)
    has_warn = any(c.status == WARN for c in checks)
    exit_code = 1 if has_fail or (args.strict and has_warn) else 0

    meta = {
        "log_dir": str(log_dir),
        "report": str(report_path) if report_path else None,
        "quality_review": str(qr_path) if qr_path else None,
        "strict": args.strict,
        "exit_code": exit_code,
    }

    if args.json:
        payload = dict(meta)
        payload["overall"] = FAIL if has_fail else (WARN if has_warn else PASS)
        payload["checks"] = [c.to_dict() for c in checks]
        print(json.dumps(payload, indent=2))
        human_output(checks, meta, sys.stderr)
    else:
        human_output(checks, meta, sys.stdout)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
