#!/usr/bin/env python3
"""
Statement-level SQL matrix for the altinity-expert-clickhouse skill packs.

Discovers every `*.sql` query pack (and, optionally, fenced ```sql blocks in
SKILL.md) under the skills directory, splits them into statements, and runs
each statement against every ClickHouse endpoint given. A statement may declare
requirements in a comment header directly above it:

    -- @check <id> <title>            identifies the check (id optional)
    -- @requires table:system.part_log, keeper, version>=25.8, kafka
    -- @skip-matrix <reason>          never run by the matrix (e.g. multi-step recipe)

Unmet requirements produce SKIP rows. Any other error is a FAIL and makes the
process exit non-zero. "No statements found" is also a failure.

Cluster placeholders: if the endpoint has a `cluster` macro and the server
expands macros inside clusterAllReplicas(), statements run unchanged. Otherwise
the placeholder is replaced by the macro value, or, on a server without any
cluster macro, `clusterAllReplicas('{cluster}', system.X)` is rewritten to
`system.X` (single-node mode), mirroring the connection skill's rule.

Usage:
  sql_matrix.py --skills ../skills --endpoint 24.8=127.0.0.1:9248 --endpoint 25.8=127.0.0.1:9258
                [--client clickhouse-client] [--user default] [--password-env CLICKHOUSE_PASSWORD]
                [--out results.csv] [--summary summary.md] [--include-skill-md] [--jobs 8]
                [--timeout 60] [--skill NAME ...]
"""
import argparse
import concurrent.futures as cf
import csv
import os
import re
import subprocess
import sys
from collections import defaultdict

CHECK_RE = re.compile(r"^\s*--\s*@check\b\s*(\S+)?\s*(.*)$")
REQ_RE = re.compile(r"^\s*--\s*@requires\b\s*(.*)$")
SKIP_RE = re.compile(r"^\s*--\s*@skip-matrix\b\s*(.*)$")
FENCE_RE = re.compile(r"```sql\s*\n(.*?)```", re.S | re.I)
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
WRITE_KW = re.compile(r"\b(KILL|SYSTEM\s+RELOAD|SYSTEM\s+STOP|SYSTEM\s+START|GRANT|REVOKE|ALTER|DROP|INSERT|CREATE|OPTIMIZE|TRUNCATE|DETACH|ATTACH)\b", re.I)
CLUSTER_FN_RE = re.compile(r"\b(clusterAllReplicas|cluster)\(\s*'\{cluster\}'\s*,\s*", re.I)
OPTIONAL_TABLES = ("part_log", "query_views_log", "crash_log", "session_log", "zookeeper_log",
                   "text_log", "query_thread_log", "backup_log", "error_log", "zookeeper_connection",
                   "projections", "kafka_consumers", "replicated_fetches", "distributed_ddl_queue")


def parse_version(v):
    parts = []
    for p in v.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            break
    while len(parts) < 2:
        parts.append(0)
    return tuple(parts[:2])


class Statement:
    def __init__(self, skill, file, idx, check_id, title, sql, requires, skip_reason):
        self.skill, self.file, self.idx = skill, file, idx
        self.check_id, self.title, self.sql = check_id, title, sql
        self.requires, self.skip_reason = requires, skip_reason


def split_statements(text, skill, file):
    """Split on ';' at end of line; collect @check/@requires headers from the comment lines above."""
    chunks, cur = [], []
    for line in text.splitlines():
        cur.append(line)
        if line.rstrip().endswith(";"):
            chunks.append("\n".join(cur))
            cur = []
    if any(l.strip() for l in cur):
        chunks.append("\n".join(cur))

    out = []
    idx = 0
    for chunk in chunks:
        lines = chunk.splitlines()
        check_id, title, requires, skip_reason = "", "", [], ""
        body_start = None
        in_block = False
        for i, l in enumerate(lines):
            s = l.strip()
            if in_block:
                if "*/" in s:
                    in_block = False
                continue
            if not s:
                continue
            if s.startswith("/*"):
                if not title:
                    title = s.lstrip("/*").strip().rstrip("*/").strip()
                if "*/" not in s:
                    in_block = True
                continue
            if s.startswith("--"):
                m = CHECK_RE.match(l)
                if m:
                    check_id = m.group(1) or ""
                    title = m.group(2).strip() or title
                    continue
                m = REQ_RE.match(l)
                if m:
                    requires += [r.strip() for r in m.group(1).split(",") if r.strip()]
                    continue
                m = SKIP_RE.match(l)
                if m:
                    skip_reason = m.group(1).strip() or "skip-matrix"
                    continue
                if not title:
                    title = s.lstrip("-").strip()
                continue
            body_start = i
            break
        if body_start is None:
            continue  # comment-only chunk
        body = "\n".join(lines[body_start:]).strip()
        if not body.rstrip(";").strip():
            continue
        idx += 1
        if not title:
            title = body.splitlines()[0][:60]
        out.append(Statement(skill, file, idx, check_id, title[:120], body, requires, skip_reason))
    return out


def discover(skills_dir, include_skill_md, only_skills):
    stmts = []
    for skill in sorted(os.listdir(skills_dir)):
        sdir = os.path.join(skills_dir, skill)
        if not os.path.isdir(sdir) or not os.path.exists(os.path.join(sdir, "SKILL.md")):
            continue
        if only_skills and skill not in only_skills and skill.replace("altinity-expert-clickhouse-", "") not in only_skills:
            continue
        for root, _dirs, files in os.walk(sdir):
            for fn in sorted(files):
                path = os.path.join(root, fn)
                rel = os.path.relpath(path, sdir)
                if fn.endswith(".sql"):
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        stmts += split_statements(fh.read(), skill, rel)
                elif include_skill_md and fn == "SKILL.md":
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                    for n, block in enumerate(FENCE_RE.findall(text), 1):
                        if set(PLACEHOLDER_RE.findall(block)) - {"cluster"}:
                            continue
                        if WRITE_KW.search(block):
                            continue
                        for st in split_statements(block, skill, "SKILL.md#block%d" % n):
                            st.idx = n
                            stmts.append(st)
    return stmts


class Endpoint:
    def __init__(self, label, hostport, args):
        self.label = label
        self.host, _, port = hostport.rpartition(":")
        self.port = port or "9000"
        self.args = args
        self.version = ""
        self.tables = set()
        self.macro = ""
        self.macro_expands = False
        self.keeper = False

    def client(self, sql, timeout):
        cmd = self.args.client.split() + ["--host", self.host, "--port", self.port, "--user", self.args.user,
                                          "--receive_timeout", str(timeout), "--max_execution_time", str(timeout),
                                          "--format", "TSVRaw", "-q", sql]
        env = os.environ.copy()
        pw = os.environ.get(self.args.password_env, "")
        if pw:
            env["CLICKHOUSE_PASSWORD"] = pw
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 60, env=env)

    def preflight(self, timeout):
        r = self.client("SELECT version()", timeout)
        if r.returncode != 0:
            raise SystemExit("endpoint %s unreachable: %s" % (self.label, r.stderr.strip()[:200]))
        self.version = r.stdout.strip()
        r = self.client("SELECT name FROM system.tables WHERE database = 'system'", timeout)
        self.tables = set(r.stdout.split())
        r = self.client("SELECT substitution FROM system.macros WHERE macro = 'cluster'", timeout)
        self.macro = r.stdout.strip() if r.returncode == 0 else ""
        self.keeper = "zookeeper_connection" in self.tables
        if self.macro:
            r = self.client("SELECT count() FROM clusterAllReplicas('{cluster}', system.one)", timeout)
            self.macro_expands = r.returncode == 0

    def rewrite(self, sql):
        if self.macro and self.macro_expands:
            return sql
        if self.macro:
            return sql.replace("{cluster}", self.macro)
        # single-node: strip the cluster wrapper
        while True:
            m = CLUSTER_FN_RE.search(sql)
            if not m:
                return sql
            open_idx = sql.index("(", m.start())
            depth, i = 0, open_idx
            while i < len(sql):
                if sql[i] == "(":
                    depth += 1
                elif sql[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            inner = sql[m.end():i].strip()
            sql = sql[:m.start()] + inner + sql[i + 1:]

    def unmet(self, requires):
        """Return a reason string if any requirement is unmet, else ''."""
        ver = parse_version(self.version)
        for req in requires:
            r = req.strip()
            if r.startswith("table:"):
                t = r[len("table:"):].strip()
                name = t.split(".", 1)[1] if t.startswith("system.") else t
                if name not in self.tables:
                    return "missing " + t
            elif r == "keeper":
                if not self.keeper:
                    return "no Keeper/ZooKeeper"
            elif r == "kafka":
                return "needs Kafka engine tables"
            elif r == "macro:cluster":
                if not self.macro:
                    return "no cluster macro"
            elif r.startswith("version>="):
                if ver < parse_version(r[len("version>="):]):
                    return "needs ClickHouse >= " + r[len("version>="):]
            elif r.startswith("version<"):
                if ver >= parse_version(r[len("version<"):]):
                    return "needs ClickHouse < " + r[len("version<"):]
            else:
                return "unknown requirement " + r
        return ""


def run_one(ep, st, timeout):
    row = dict(skill=st.skill, file=st.file, idx=st.idx, check_id=st.check_id, title=st.title,
               endpoint=ep.label, version=ep.version, status="", reason="", code="", stderr="")
    if st.skip_reason:
        row["status"], row["reason"] = "SKIP", st.skip_reason
        return row
    reason = ep.unmet(st.requires)
    if reason:
        row["status"], row["reason"] = "SKIP", reason
        return row
    sql = ep.rewrite(st.sql).rstrip().rstrip(";")
    try:
        r = ep.client(sql, timeout)
    except subprocess.TimeoutExpired:
        row["status"], row["reason"], row["code"] = "FAIL", "client timeout", "TIMEOUT"
        return row
    if r.returncode == 0:
        row["status"] = "PASS"
        return row
    err = r.stderr.strip().replace("\n", " ")
    m = re.search(r"Code:\s*(\d+)", err)
    row["code"] = m.group(1) if m else str(r.returncode)
    err = re.sub(r"Received exception from server \(version [^)]*\):\s*", "", err)
    err = re.sub(r"Received from [^ ]+\.\s*", "", err)
    err = err.replace("DB::Exception: ", "")
    row["stderr"] = err[:400]
    row["status"] = "FAIL"
    # hint for optional tables that were not declared
    m = re.search(r"Unknown table expression identifier '?([\w.]+)", err)
    if m:
        row["reason"] = "undeclared optional table? add `-- @requires table:%s`" % m.group(1)
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--skills", required=True)
    ap.add_argument("--endpoint", action="append", required=True, help="LABEL=host:port")
    ap.add_argument("--client", default="clickhouse-client")
    ap.add_argument("--user", default="default")
    ap.add_argument("--password-env", default="CLICKHOUSE_PASSWORD")
    ap.add_argument("--out", default="results/sql-matrix.csv")
    ap.add_argument("--summary", default="results/sql-matrix.md")
    ap.add_argument("--include-skill-md", action="store_true")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--skill", action="append", default=[], help="limit to these skills (repeatable)")
    args = ap.parse_args()

    eps = []
    for e in args.endpoint:
        label, _, hp = e.partition("=")
        eps.append(Endpoint(label, hp or label, args))
    for ep in eps:
        ep.preflight(args.timeout)
        print("endpoint %-8s version=%-12s tables=%d macro=%r macro_expands=%s keeper=%s" % (
            ep.label, ep.version, len(ep.tables), ep.macro, ep.macro_expands, ep.keeper), file=sys.stderr)

    stmts = discover(args.skills, args.include_skill_md, set(args.skill))
    if not stmts:
        print("FAIL: no statements discovered under %s" % args.skills, file=sys.stderr)
        sys.exit(2)
    print("discovered %d statements in %d skills" % (len(stmts), len({s.skill for s in stmts})), file=sys.stderr)

    jobs = [(ep, st) for st in stmts for ep in eps]
    rows = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for row in ex.map(lambda j: run_one(j[0], j[1], args.timeout), jobs):
            rows.append(row)
    rows.sort(key=lambda r: (r["skill"], r["file"], int(r["idx"]), r["endpoint"]))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    # summary
    per_ep = defaultdict(lambda: defaultdict(int))
    for r in rows:
        per_ep[r["endpoint"]][r["status"]] += 1
    fails = [r for r in rows if r["status"] == "FAIL"]
    skips = defaultdict(list)
    for r in rows:
        if r["status"] == "SKIP":
            skips[(r["skill"], r["file"], r["idx"], r["title"])].append("%s (%s)" % (r["endpoint"], r["reason"]))

    lines = ["# SQL matrix summary", "", "| endpoint | version | PASS | SKIP | FAIL |", "|---|---|---|---|---|"]
    for ep in eps:
        c = per_ep[ep.label]
        lines.append("| %s | %s | %d | %d | %d |" % (ep.label, ep.version, c["PASS"], c["SKIP"], c["FAIL"]))
    lines += ["", "## Failures (%d)" % len(fails), ""]
    if fails:
        lines += ["| skill | file | # | check | endpoint | code | error |", "|---|---|---|---|---|---|---|"]
        for r in fails:
            lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                r["skill"].replace("altinity-expert-clickhouse-", ""), r["file"], r["idx"],
                (r["check_id"] + " " + r["title"]).strip()[:60].replace("|", "/"), r["endpoint"], r["code"],
                r["stderr"][:160].replace("|", "/")))
    else:
        lines.append("none")
    lines += ["", "## Skipped statements (%d)" % len(skips), ""]
    for (skill, file, idx, title), eplist in sorted(skips.items()):
        lines.append("- %s/%s #%s %s: %s" % (skill.replace("altinity-expert-clickhouse-", ""), file, idx,
                                             title[:50], "; ".join(eplist)))
    with open(args.summary, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines[:len(eps) + 4]), file=sys.stderr)
    print("results: %s  summary: %s" % (args.out, args.summary), file=sys.stderr)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
