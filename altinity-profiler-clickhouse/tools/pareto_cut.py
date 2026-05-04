"""
pareto_cut.py — Phase 5a → Phase 6 helper.

Takes the top-50 table list produced by the 5a workload-shape query
(rows: full_name, execs, total_ms, sels, ins, users) plus optional
schema metadata (engine, total_rows) and applies the Phase 6 demotion
algorithm to split analyst-hot from pipeline-hot.

Returns:
  - analyst_hot: list of rows that survive demotion (the Pareto cut)
  - demoted: list of rows demoted, each with reasons attached

The model still owns the un-demote caveats (shadow-traffic, per-tenant
hash patterns) that need judgment — those are flagged for review here,
not auto-resolved.

Decision rules match pipeline.md §6.

Archetype-aware demotion (pipeline.md §1.5 → §6): when the primary
archetype is `B` (sharded OLAP) and the cluster has a large number of
business tables (the huge-enterprise sub-pattern from
`audit-groups.md` rule 1, threshold ~5000 biz tables), the helper is
more aggressive on Rule 2 (service-users-only) by lowering the
"all users service" requirement to "≥ 90% service users" — large B
clusters tend to have a long tail of one-off human queries on tables
that are otherwise pipeline-only, and the default rule keeps too many
of them hot.

Run offline:

    python3 pareto_cut.py top50.json [schema.json] \\
        [--service-users default,airflow,clickhouse] \\
        [--archetype B] [--biz-tabs 6200]
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable

DEFAULT_SERVICE_USERS = frozenset(
    {"default", "clickhouse", "airflow", "bot", "monitor", "oncall", ""}
)
SERVICE_USER_PATTERNS = [
    re.compile(r"^airflow"),
    re.compile(r"^bot"),
    re.compile(r"^monitor"),
    re.compile(r"^oncall"),
]

INFRA_ENGINES = frozenset({"Kafka", "Null", "Buffer", "MaterializedView"})

STAGING_SUFFIXES = ("_new", "_tmp", "_staging", "_old", "_backup")
INNER_PREFIXES = (".inner.mv_", ".inner_id.")

PER_TENANT_PATTERN = re.compile(r"_[0-9a-f]{8,}_")
SHADOW_TRAFFIC_PATTERN = re.compile(r"_test_v\d+$")
SHADOW_TRAFFIC_RIVAL_RATIO = 0.5  # exec count >= 50% of base counts as live

# Huge-enterprise sub-pattern of archetype B (rule 1 in audit-groups.md):
# clusters with this many business tables get more aggressive Rule 2
# enforcement — the long tail of one-off human queries against
# pipeline tables otherwise floods the analyst-hot set.
B_HUGE_ENTERPRISE_BIZ_TABS = 5000
B_HUGE_ENTERPRISE_SERVICE_FRACTION = 0.9


@dataclass
class TableRow:
    full_name: str
    execs: int = 0
    total_ms: int = 0
    sels: int = 0
    ins: int = 0
    users: tuple[str, ...] = ()
    engine: str | None = None
    total_rows: int | None = None
    reasons: list[str] = field(default_factory=list)
    review_flags: list[str] = field(default_factory=list)

    @property
    def short_name(self) -> str:
        return self.full_name.split(".", 1)[-1]


def _is_service_user(u: str, service_users: frozenset[str]) -> bool:
    if u in service_users:
        return True
    return any(p.match(u) for p in SERVICE_USER_PATTERNS)


def _all_service_users(users: Iterable[str], service_users: frozenset[str]) -> bool:
    users = list(users)
    if not users:
        return False  # no signal, don't demote
    return all(_is_service_user(u, service_users) for u in users)


def _mostly_service_users(users: Iterable[str], service_users: frozenset[str],
                          fraction: float) -> bool:
    users = list(users)
    if not users:
        return False
    n_service = sum(1 for u in users if _is_service_user(u, service_users))
    return (n_service / len(users)) >= fraction


def demote(
    rows: list[TableRow],
    service_users: frozenset[str] = DEFAULT_SERVICE_USERS,
    archetype: str | None = None,
    biz_tabs: int | None = None,
) -> tuple[list[TableRow], list[TableRow]]:
    """Apply Phase 6 demotion. Returns (analyst_hot, demoted).

    `archetype` (one of A/B/C/D/E) and `biz_tabs` come from Phase 1.5.
    When archetype is `B` and biz_tabs > B_HUGE_ENTERPRISE_BIZ_TABS,
    Rule 2 uses the looser "mostly service users" check.
    """
    huge_b = (
        archetype == "B"
        and biz_tabs is not None
        and biz_tabs > B_HUGE_ENTERPRISE_BIZ_TABS
    )
    base_execs: dict[str, int] = {}
    for r in rows:
        m = SHADOW_TRAFFIC_PATTERN.search(r.short_name)
        if not m:
            base_execs[r.full_name] = r.execs

    analyst_hot: list[TableRow] = []
    demoted: list[TableRow] = []

    for r in rows:
        reasons: list[str] = []
        review: list[str] = []

        # Rule 1: insert-dominated
        total = r.sels + r.ins
        if r.ins > 0 and total > 0 and (r.ins / total) > 0.9:
            reasons.append("insert-dominated")

        # Rule 2: service-users-only (or mostly-service for huge B)
        if huge_b:
            if _mostly_service_users(
                r.users, service_users, B_HUGE_ENTERPRISE_SERVICE_FRACTION
            ):
                reasons.append(
                    f"mostly-service-users (≥"
                    f"{int(B_HUGE_ENTERPRISE_SERVICE_FRACTION * 100)}%; "
                    f"archetype B huge-enterprise)"
                )
        elif _all_service_users(r.users, service_users):
            reasons.append("service-users-only")

        # Rule 4: engine-by-nature
        if r.engine and r.engine in INFRA_ENGINES:
            reasons.append(f"engine-is-infra:{r.engine}")
        if any(r.short_name.startswith(p) for p in INNER_PREFIXES):
            reasons.append("inner-mv-storage")

        # Rule 5: staging naming
        if any(r.short_name.endswith(s) for s in STAGING_SUFFIXES):
            # Caveat: a staging-named table that is select-dominated by
            # non-service users is misleadingly named, not actual
            # staging. Flag for review and don't auto-demote on name
            # alone — the suffix is a naming convention, not a status.
            select_dominated = total > 0 and (r.sels / total) > 0.7
            user_signal_is_human = r.users and not _all_service_users(
                r.users, service_users
            )
            if select_dominated and user_signal_is_human:
                review.append(
                    "misleading-staging-name: select-dominated by human "
                    "users; kept hot — confirm with catalog owner"
                )
            else:
                reasons.append("staging-name")

        # Caveat: shadow-traffic test sibling
        m = SHADOW_TRAFFIC_PATTERN.search(r.short_name)
        if m:
            base_name = r.full_name[: -len(m.group(0))]
            base = base_execs.get(base_name)
            if base and r.execs >= base * SHADOW_TRAFFIC_RIVAL_RATIO:
                # un-demote: this is shadow traffic, not a sandbox
                if "staging-name" in reasons:
                    reasons.remove("staging-name")
                review.append(
                    f"shadow-traffic-vs-{base_name}: kept hot "
                    f"(execs={r.execs} vs base={base})"
                )
            else:
                review.append("looks-like-test-sibling")

        # Caveat: per-tenant hash pattern (pattern-once, not per-tenant)
        if PER_TENANT_PATTERN.search(r.short_name):
            review.append("per-tenant-hash-pattern: summarize once, do not enumerate")

        r.reasons = reasons
        r.review_flags = review

        if reasons:
            demoted.append(r)
        else:
            analyst_hot.append(r)

    return analyst_hot, demoted


def render_summary(
    analyst_hot: list[TableRow],
    demoted: list[TableRow],
    target_count: int = 20,
) -> str:
    lines = []
    lines.append(f"# Pareto cut summary")
    lines.append("")
    lines.append(
        f"- analyst_hot: {len(analyst_hot)} (target {target_count}; "
        f"trim further by hot-column thinness or co-occurrence rule 3)"
    )
    lines.append(f"- demoted: {len(demoted)}")
    lines.append("")
    lines.append("## Analyst-hot")
    for r in analyst_hot[:target_count]:
        flag = (
            f"  ⚠ {'; '.join(r.review_flags)}" if r.review_flags else ""
        )
        lines.append(f"- `{r.full_name}` execs={r.execs} sels={r.sels}{flag}")
    if len(analyst_hot) > target_count:
        lines.append(f"  …and {len(analyst_hot) - target_count} more (trim)")
    lines.append("")
    lines.append("## Demoted (with reasons)")
    for r in demoted:
        lines.append(f"- `{r.full_name}` — {', '.join(r.reasons)}")
    return "\n".join(lines)


if __name__ == "__main__":
    import argparse
    import json

    ap = argparse.ArgumentParser()
    ap.add_argument("top50_json")
    ap.add_argument("schema_json", nargs="?", default=None)
    ap.add_argument("--service-users", default=None,
                    help="Comma-separated override (e.g. default,clickhouse_operator,airflow)")
    ap.add_argument("--target", type=int, default=20)
    ap.add_argument("--archetype", default=None,
                    help="Phase 1.5 primary archetype letter (A/B/C/D/E)")
    ap.add_argument("--biz-tabs", type=int, default=None,
                    help="Business-table count from Phase 1.5 (used with --archetype B)")
    args = ap.parse_args()

    with open(args.top50_json) as f:
        rows_raw = json.load(f)

    schema_by_name: dict[str, dict] = {}
    if args.schema_json:
        with open(args.schema_json) as f:
            for s in json.load(f):
                schema_by_name[s["full_name"]] = s

    rows = []
    for r in rows_raw:
        s = schema_by_name.get(r["full_name"], {})
        rows.append(
            TableRow(
                full_name=r["full_name"],
                execs=int(r.get("execs", 0)),
                total_ms=int(r.get("total_ms", 0)),
                sels=int(r.get("sels", 0)),
                ins=int(r.get("ins", 0)),
                users=tuple(r.get("users", [])),
                engine=s.get("engine"),
                total_rows=s.get("total_rows"),
            )
        )

    service = (
        frozenset(args.service_users.split(","))
        if args.service_users
        else DEFAULT_SERVICE_USERS
    )

    archetype = args.archetype.upper() if args.archetype else None
    analyst_hot, demoted = demote(
        rows, service, archetype=archetype, biz_tabs=args.biz_tabs
    )
    print(render_summary(analyst_hot, demoted, target_count=args.target))
