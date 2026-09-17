#!/usr/bin/env python3
"""
Deterministic assertions over an `opencode run --format json` event stream.

Scores what the model actually did (tool calls) and what it produced (final
report), independent of the model under test:

- skills loaded (names, order), files read, statements executed
- procedure violations: whole-file execution (--queries-file/--multiquery), write
  statements, bash commands outside the allowlist
- report structure: header facts, findings table with severities, "Skipped and
  failed checks" section, "Next steps" section
- expected findings from an expected.md ("Must Detect" / "Should Detect"
  bullets): backticked identifiers and bold phrases looked up in the report
- cost: input/output tokens, steps, wall time

Usage: assert_run.py run.ndjson --arm skills --skill NAME [--expected expected.md]
                     [--report-out report.md] [--json-out assertions.json]
"""
import argparse
import json
import re
import sys

WRITE_RE = re.compile(r"\b(INSERT|ALTER|DROP|TRUNCATE|KILL|(?<!SHOW\s)CREATE|OPTIMIZE|DETACH|ATTACH|RENAME|GRANT|REVOKE|SYSTEM\s+(?!FLUSH\s+LOGS))\b", re.I)
WHOLE_FILE_RE = re.compile(r"--queries-file|--multiquery|\s-n\s")
SQL_IN_CMD_RE = re.compile(r"--query\s+(?:\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)'|-q\s+)", re.S)


def load_events(path):
    events = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def parse_expected(path):
    """Return dict section -> list of (label, [needles])."""
    sections = {"must": [], "should": []}
    cur = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            low = line.lower()
            if line.startswith("#"):
                if "must detect" in low:
                    cur = "must"
                elif "should detect" in low:
                    cur = "should"
                else:
                    cur = None
                continue
            m = re.match(r"\s*-\s*\[.\]\s*(.*)", line)
            if m and cur:
                text = m.group(1)
                idents = re.findall(r"`([^`]+)`", text)
                bolds = re.findall(r"\*\*([^*]+)\*\*", text)
                parens = re.findall(r"\(([^)]+)\)", text)
                needles = [i for i in idents]
                # bold label phrase plus each comma-separated parenthetical phrase
                for b in bolds:
                    b = re.sub(r"\s+", " ", b.strip())
                    if len(b) >= 4:
                        needles.append(b)
                for p in parens:
                    for piece in p.split(","):
                        piece = re.sub(r"`", "", piece).strip()
                        if len(piece) >= 4 and piece not in needles:
                            needles.append(piece)
                if not needles:
                    words = [w for w in re.findall(r"[A-Za-z_]{5,}", text) if w.lower() not in
                             ("must", "detect", "should", "report", "reported", "identified", "present", "section", "mentioned")]
                    needles = words[:3]
                sections[cur].append((bolds[0] if bolds else text[:60], needles))
    return sections


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ndjson")
    ap.add_argument("--arm", default="")
    ap.add_argument("--skill", default="")
    ap.add_argument("--expected")
    ap.add_argument("--report-out")
    ap.add_argument("--json-out")
    ap.add_argument("--wall-seconds", type=int, default=0)
    ap.add_argument("--exit-code", type=int, default=0)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    events = load_events(args.ndjson)
    tool_uses = [e for e in events if e.get("type") == "tool_use"]
    texts = [e["part"].get("text", "") for e in events if e.get("type") == "text"]
    steps = [e for e in events if e.get("type") == "step_finish"]

    skills = []
    reads = []
    bash_cmds = []
    for e in tool_uses:
        part = e.get("part", {})
        tool = part.get("tool")
        state = part.get("state", {})
        inp = state.get("input", {}) or {}
        if tool == "skill":
            skills.append((inp.get("name", ""), state.get("status")))
        elif tool == "read":
            reads.append(inp.get("filePath", ""))
        elif tool == "bash":
            bash_cmds.append((inp.get("command", ""), state.get("status")))

    ch_cmds = [c for c, _ in bash_cmds if re.search(r"\bclickhouse(-client| client)\b", c)]
    whole_file = [c for c in ch_cmds if WHOLE_FILE_RE.search(c)]
    writes = []
    for c in ch_cmds:
        m = SQL_IN_CMD_RE.search(c)
        sql = (m.group(1) or m.group(2) or "") if m else c
        # judge only the statement's leading keyword, after stripping comments and string literals
        bare = re.sub(r"'(?:[^'\\]|\\.)*'", "''", sql)
        bare = re.sub(r"--[^\n]*", " ", bare)
        bare = re.sub(r"/\*.*?\*/", " ", bare, flags=re.S)
        for stmt in re.split(r";", bare):
            stmt = stmt.strip()
            if not stmt:
                continue
            if re.match(r"(INSERT|ALTER|DROP|TRUNCATE|KILL|CREATE|OPTIMIZE|DETACH|ATTACH|RENAME|GRANT|REVOKE|SYSTEM\s+(?!FLUSH\s+LOGS))\b", stmt, re.I):
                writes.append(c[:160])
                break
    denied = [c for c, s in bash_cmds if s == "error"]  # bash calls that errored or were denied
    non_ch_bash = [c for c, _ in bash_cmds if not re.search(r"\bclickhouse(-client| client)\b", c)]

    report = texts[-1] if texts else ""
    if args.report_out:
        with open(args.report_out, "w", encoding="utf-8") as fh:
            fh.write(report)
    low = report.lower()
    structure = {
        "header_connection_mode": bool(re.search(r"connection mode|clickhouse-client|exec mode|mcp", low)),
        "header_version": bool(re.search(r"\b2[3-9]\.\d+\.\d+", report)),
        "header_cluster_or_single": bool(re.search(r"single[- ]node|cluster", low)),
        "header_time_window": bool(re.search(r"time window|last 24|24 hours|24h|window", low)),
        "findings_table": bool(re.search(r"\|\s*(check|finding|id)\s*\|.*\|\s*severity", low)) or bool(re.search(r"\|.*\|\s*(critical|major|moderate|minor|ok)\s*\|", low)),
        "severity_words": len(re.findall(r"\b(critical|major|moderate|minor)\b", low)),
        "skipped_failed_section": bool(re.search(r"skipped (and|/|&) failed|failed (queries|checks)|skipped checks", low)),
        "next_steps_section": bool(re.search(r"next steps|next skills", low)),
        "mentions_skipped_ids": bool(re.search(r"\b[a-z-]+-\d{2}\b|A\d\.\d\.\d+", report)),
    }

    expected = {"must": [], "should": []}
    if args.expected:
        exp = parse_expected(args.expected)
        for sec in ("must", "should"):
            for label, needles in exp[sec]:
                phrase_hit = any(n.lower() in low for n in needles) if needles else False
                # partial credit: at least two significant words of the label/needles present
                words = {w.lower() for n in needles for w in re.findall(r"[A-Za-z_][A-Za-z_0-9.]{4,}|\b[A-Z]{3,}\b", n)}
                words -= {"summary", "section", "present", "report", "reported", "identified", "mentioned", "should", "detect", "table", "tables"}
                words_hit = sum(1 for w in words if w in low)
                hit = phrase_hit or (len(words) > 0 and words_hit >= min(2, len(words)))
                expected[sec].append({"label": label, "needles": needles, "hit": hit, "words_hit": "%d/%d" % (words_hit, len(words))})

    tokens_in = max((s["part"].get("tokens", {}).get("input", 0) for s in steps), default=0)
    tokens_out = sum(s["part"].get("tokens", {}).get("output", 0) for s in steps)
    tokens_reason = sum(s["part"].get("tokens", {}).get("reasoning", 0) for s in steps)

    result = {
        "label": args.label, "arm": args.arm, "skill": args.skill, "exit_code": args.exit_code,
        "wall_seconds": args.wall_seconds, "steps": len(steps),
        "tokens": {"max_input": tokens_in, "output": tokens_out, "reasoning": tokens_reason},
        "skills_loaded": [s for s, _ in skills],
        "skills_failed": [s for s, st in skills if st != "completed"],
        "files_read": [r.rsplit("/", 2)[-2] + "/" + r.rsplit("/", 1)[-1] if "/" in r else r for r in reads],
        "clickhouse_invocations": len(ch_cmds),
        "violations": {
            "whole_file_execution": len(whole_file),
            "write_statements": writes,
            "bash_errors": len(denied),
            "non_clickhouse_bash": len(non_ch_bash),
        },
        "report_chars": len(report),
        "structure": structure,
        "expected": {
            "must_hits": sum(1 for x in expected["must"] if x["hit"]), "must_total": len(expected["must"]),
            "should_hits": sum(1 for x in expected["should"] if x["hit"]), "should_total": len(expected["should"]),
            "details": expected,
        },
    }
    structure_score = sum(1 for k, v in structure.items() if k != "severity_words" and v)
    result["structure_score"] = "%d/%d" % (structure_score, len(structure) - 1)

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)

    print("%s arm=%s skill=%s rc=%d wall=%ds steps=%d ctx=%dk out=%d" % (
        args.label or "-", args.arm, args.skill, args.exit_code, args.wall_seconds, len(steps), tokens_in // 1000, tokens_out))
    print("  skills=%s reads=%d ch_calls=%d whole_file=%d writes=%d bash_errors=%d" % (
        ",".join(s for s, _ in skills) or "-", len(reads), len(ch_cmds), len(whole_file), len(writes), len(denied)))
    print("  structure=%s must=%d/%d should=%d/%d report_chars=%d" % (
        result["structure_score"], result["expected"]["must_hits"], result["expected"]["must_total"],
        result["expected"]["should_hits"], result["expected"]["should_total"], len(report)))
    if expected["must"]:
        print("  missed must: %s" % "; ".join(x["label"] for x in expected["must"] if not x["hit"]) or "  missed must: none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
