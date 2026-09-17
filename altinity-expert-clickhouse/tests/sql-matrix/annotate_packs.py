#!/usr/bin/env python3
"""
Stamp `-- @check <id> <title>` and `-- @requires ...` headers onto every
statement of the skill query packs, so that models and the SQL matrix can
identify checks and skip statements whose optional tables are absent.

Idempotent: statements that already carry an @check header keep their id;
@requires lines are added only for optional tables referenced by the statement
and not already declared.

Usage: annotate_packs.py --skills ../skills [--dry-run] [--skill NAME ...]
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sql_matrix import split_statements, CHECK_RE, REQ_RE, SKIP_RE  # noqa: E402

# system tables that are absent unless configured, plus tables that need Keeper.
OPTIONAL_TABLES = {
    "part_log": "table:system.part_log",
    "query_views_log": "table:system.query_views_log",
    "crash_log": "table:system.crash_log",
    "session_log": "table:system.session_log",
    "zookeeper_log": "table:system.zookeeper_log",
    "text_log": "table:system.text_log",
    "query_thread_log": "table:system.query_thread_log",
    "backup_log": "table:system.backup_log",
    "error_log": "table:system.error_log",
    "projections": "table:system.projections",
    "asynchronous_metric_log": "table:system.asynchronous_metric_log",
    "metric_log": "table:system.metric_log",
    "zookeeper_connection": "keeper",
    "distributed_ddl_queue": "keeper",
    "zookeeper": "keeper",
}
TABLE_RE = re.compile(r"\bsystem\.(\w+)")

SHORT = {
    "checks.sql": "",
}


def skill_short(skill):
    return skill.replace("altinity-expert-clickhouse-", "")


def file_short(fn):
    stem = os.path.splitext(os.path.basename(fn))[0]
    return "" if stem == "checks" else stem.replace("_", "-") + "-"


def strip_noise(sql):
    """Remove comments and string literals so that only real table references remain.

    A pack often names a system table inside a literal (a severity message, or
    `'system.part_log' AS object`) while reading something else entirely, so
    scanning the raw text would declare dependencies the statement does not have.
    """
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"'(?:[^'\\]|\\.)*'", "''", sql)
    return sql


def annotate_file(path, skill, rel, dry_run):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    stmts = split_statements(text, skill, rel)
    if not stmts:
        return 0
    # Re-split raw chunks the same way to edit in place.
    chunks, cur = [], []
    for line in text.splitlines(keepends=True):
        cur.append(line)
        if line.rstrip().endswith(";"):
            chunks.append("".join(cur))
            cur = []
    if cur:
        chunks.append("".join(cur))

    out, idx, changed = [], 0, 0
    for chunk in chunks:
        lines = chunk.splitlines(keepends=True)
        # find first SQL line (skip blank/comment lines, handling block comments)
        body_start, in_block = None, False
        for i, l in enumerate(lines):
            s = l.strip()
            if in_block:
                if "*/" in s:
                    in_block = False
                continue
            if not s:
                continue
            if s.startswith("/*"):
                if "*/" not in s:
                    in_block = True
                continue
            if s.startswith("--"):
                continue
            body_start = i
            break
        if body_start is None or not "".join(lines[body_start:]).strip().rstrip(";").strip():
            out.append(chunk)
            continue
        idx += 1
        head = lines[:body_start]
        body = lines[body_start:]
        has_check = any(CHECK_RE.match(l) for l in head)
        declared = []
        for l in head:
            m = REQ_RE.match(l)
            if m:
                declared += [r.strip() for r in m.group(1).split(",") if r.strip()]
        skip = any(SKIP_RE.match(l) for l in head)

        # title: first non-decorative comment line in head
        title = ""
        for l in head:
            s = l.strip()
            if s.startswith("--"):
                t = s.lstrip("-").strip()
                if t and not set(t) <= set("-=") and not t.startswith("@"):
                    title = t
                    break
            elif s.startswith("/*"):
                t = s.strip("/*").strip().rstrip("*/").strip()
                if t:
                    title = t
                    break
        if not title:
            title = body[0].strip()[:60]
        title = re.sub(r"^\d+[.)]\s*", "", title)  # drop leading "1) " / "3. "

        # id: prefer an Altinity id literal in the SQL, e.g. 'A3.0.5' AS id
        sql_text = "".join(body)
        m = re.search(r"'(A\d+(?:\.\d+)+)'\s+AS\s+id", sql_text, re.I)
        if m:
            check_id = m.group(1)
        else:
            check_id = "%s-%s%02d" % (skill_short(skill), file_short(rel), idx)

        needed = []
        for t in sorted(set(TABLE_RE.findall(strip_noise(sql_text)))):
            req = OPTIONAL_TABLES.get(t)
            if req and req not in declared and req not in needed:
                needed.append(req)

        new_head = list(head)
        insert_at = len(new_head)
        # place new header lines right before the body, after existing comments
        additions = []
        if not has_check and not skip:
            additions.append("-- @check %s %s\n" % (check_id, title))
        if needed:
            additions.append("-- @requires %s\n" % ", ".join(needed))
        if additions:
            changed += 1
            new_head[insert_at:insert_at] = additions
        out.append("".join(new_head) + "".join(body))

    new_text = "".join(out)
    if new_text != text and not dry_run:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new_text)
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skills", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="report what is missing and exit 1 if any header would be added (implies --dry-run)")
    ap.add_argument("--skill", action="append", default=[])
    args = ap.parse_args()
    if args.check:
        args.dry_run = True
    total = 0
    for skill in sorted(os.listdir(args.skills)):
        sdir = os.path.join(args.skills, skill)
        if not os.path.isdir(sdir) or not os.path.exists(os.path.join(sdir, "SKILL.md")):
            continue
        if args.skill and skill not in args.skill and skill_short(skill) not in args.skill:
            continue
        for root, _d, files in os.walk(sdir):
            for fn in sorted(files):
                if fn.endswith(".sql"):
                    path = os.path.join(root, fn)
                    n = annotate_file(path, skill, os.path.relpath(path, sdir), args.dry_run)
                    if n:
                        print("%s/%s: %d statements annotated" % (skill_short(skill), os.path.relpath(path, sdir), n))
                        total += n
    print("total annotated: %d%s" % (total, " (dry run)" if args.dry_run else ""))
    if args.check and total:
        print("query pack headers are out of date: run `make -C tests annotate-packs`", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
