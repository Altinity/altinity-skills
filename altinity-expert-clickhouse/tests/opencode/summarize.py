#!/usr/bin/env python3
"""Summarize assertions.json files under a suite output directory as a markdown table."""
import glob
import json
import os
import sys


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    rows = []
    for path in sorted(glob.glob(os.path.join(root, "*", "assertions.json"))):
        with open(path, encoding="utf-8") as fh:
            a = json.load(fh)
        v = a["violations"]
        s = a["structure"]
        e = a["expected"]
        rows.append({
            "run": a.get("label") or os.path.basename(os.path.dirname(path)),
            "arm": a["arm"],
            "rc": a["exit_code"],
            "wall_s": a["wall_seconds"],
            "steps": a["steps"],
            "ctx_k": a["tokens"]["max_input"] // 1000,
            "out_tok": a["tokens"]["output"],
            "skills": len(a["skills_loaded"]),
            "reads": len(a["files_read"]),
            "ch_calls": a["clickhouse_invocations"],
            "whole_file": v["whole_file_execution"],
            "writes": len(v["write_statements"]),
            "bash_err": v["bash_errors"],
            "structure": a["structure_score"],
            "skipped_sec": "y" if s["skipped_failed_section"] else "n",
            "must": "%d/%d" % (e["must_hits"], e["must_total"]),
            "should": "%d/%d" % (e["should_hits"], e["should_total"]),
            "report_chars": a["report_chars"],
        })
    if not rows:
        print("no assertions.json found under", root)
        return 1
    cols = list(rows[0].keys())
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for r in rows:
        print("| " + " | ".join(str(r[c]) for c in cols) + " |")

    # per-arm aggregates
    arms = {}
    for r in rows:
        a = arms.setdefault(r["arm"] if r["arm"] != "skills" else ("old" if "-old" in r["run"] else "new"), [])
        a.append(r)
    def frac(v):
        n, d = v.split("/")
        return int(n), int(d)
    print("\n| arm | runs | avg wall_s | avg ctx_k | avg out_tok | avg ch_calls | whole_file | bash_err | structure | must | should |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for arm in sorted(arms):
        rs = arms[arm]
        n = len(rs)
        sn = sum(frac(r["structure"])[0] for r in rs); sd = sum(frac(r["structure"])[1] for r in rs)
        mn = sum(frac(r["must"])[0] for r in rs); md = sum(frac(r["must"])[1] for r in rs)
        hn = sum(frac(r["should"])[0] for r in rs); hd = sum(frac(r["should"])[1] for r in rs)
        print("| %s | %d | %d | %d | %d | %d | %d | %d | %d/%d | %d/%d | %d/%d |" % (
            arm, n, sum(r["wall_s"] for r in rs) / n, sum(r["ctx_k"] for r in rs) / n, sum(r["out_tok"] for r in rs) / n,
            sum(r["ch_calls"] for r in rs) / n, sum(r["whole_file"] for r in rs), sum(r["bash_err"] for r in rs), sn, sd, mn, md, hn, hd))
    return 0


if __name__ == "__main__":
    sys.exit(main())
