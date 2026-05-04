"""
synthesize_conventions.py — Phase 5d.1 helper.

Takes the row of counts produced by the form-mining query (one row,
columns: uses_prewhere, uses_where_only, uses_final, uses_argmax,
uses_anylast, uses_todate, uses_tostartofday, uses_select_star, total)
and emits ready-to-paste markdown bullets for the "From the corpus
(mined)" subsection of patterns.md.

Usage from the profiler's synthesis phase:

    counts = mcp_run_query(form_mining_sql)[0]   # single-row result
    bullets = synthesize(counts, top_fact="<db>.<table>",
                         archetypes={"C"},
                         top_fact_has_anylast_simple_agg=True)
    # paste bullets into patterns.md

Decision rules match pipeline.md §5d.1. A form ratio ≤ 0.5 yields no
bullet (silence is the default). The PREWHERE axis is the one
exception: if a tenant-leading sort key is involved and the corpus
shows roughly even split, emit an explicit `no dominant form` note
so the analyst doesn't assume one.

Each bullet carries a stable bullet ID (B1..B4) so archetype modules
can reference and override deterministically:

  B1-prewhere               PREWHERE vs WHERE
  B2-anylast-vs-argmax      latest-row idiom on AggMT
  B3-todate-vs-tostartofday daily bucket form
  B4-select-star            wide-projection note

Archetype-driven overrides (loaded via `archetypes` parameter):

  C: when `top_fact_has_anylast_simple_agg=True`, B2 is hard-suppressed
     and replaced with the engine-native bullet. The corpus prevalence
     is irrelevant — `argMax(col, <ts>)` produces inconsistent results
     against `SimpleAggregateFunction(anyLast, …)` columns regardless.

  C with SummingMergeTree top fact: any "counting" bullet (count() vs
     sum(1)) is suppressed because the engine has its own answer
     (`sum(<count_col>)` or `countMerge(<state>)`). This script
     currently emits no count bullet at all, so the rule is a no-op
     today; reserved for future expansion.

This script is deterministic — no network, no model. Run it offline
against the mining-query JSON.
"""

from __future__ import annotations

DOMINANT = 0.5
SELECT_STAR_NOTE_THRESHOLD = 0.05

# Archetype-C engine-native replacement for B2 when the top fact has
# any SimpleAggregateFunction(anyLast, …) column. Corpus prevalence is
# irrelevant; argMax is semantically wrong against that column type.
_ARCHETYPE_C_B2_REPLACEMENT = (
    "**Latest-row idiom on AggMT**: `anyLast(col)` over `FINAL`, NOT "
    "`argMax(col, ts)` — the engine stores "
    "`SimpleAggregateFunction(anyLast, …)`, so `anyLast` is the "
    "engine-native path. Corpus prevalence is irrelevant; `argMax` on "
    "a different timestamp column produces inconsistent results "
    "(see archetype C trap [trap-C1])."
)


def _ratio(num: int, denom: int) -> float | None:
    if denom <= 0:
        return None
    return num / denom


def _pct(r: float) -> str:
    return f"{round(r * 100)}%"


def _bullet_b1(counts: dict[str, int], top_fact: str,
               tenant_leads_sort_key: bool) -> str | None:
    pw = counts.get("uses_prewhere", 0)
    wo = counts.get("uses_where_only", 0)
    r = _ratio(pw, pw + wo)
    if r is None:
        return None
    if r > DOMINANT:
        return (
            f"**Filter form**: `PREWHERE` the tenant + date filters "
            f"(observed in ~{_pct(r)} of hot queries on "
            f"`{top_fact}`; the optimizer often hoists from `WHERE`, "
            f"but the explicit form is the cluster idiom and easier "
            f"to read)."
        )
    if tenant_leads_sort_key:
        return (
            f"`no dominant form-level convention observed for filter "
            f"keyword (PREWHERE vs WHERE)` — corpus is ~{_pct(r)} "
            f"PREWHERE / ~{_pct(1 - r)} WHERE on `{top_fact}`. "
            f"Don't assume one; the optimizer hoists when safe."
        )
    return None


def _bullet_b2(counts: dict[str, int]) -> str | None:
    al = counts.get("uses_anylast", 0)
    am = counts.get("uses_argmax", 0)
    r = _ratio(al, al + am)
    if r is None or counts.get("uses_final", 0) <= 0:
        return None
    if r > DOMINANT:
        return (
            f"**Latest-row idiom on AggMT**: `anyLast(col)` over "
            f"`FINAL`, not `argMax(col, ts)` (observed in "
            f"~{_pct(r)} of AggMT-touching queries; the engine "
            f"stores `SimpleAggregateFunction(anyLast, …)` so "
            f"`anyLast` is the engine-native path)."
        )
    if r < (1 - DOMINANT):
        return (
            f"**Latest-row idiom**: `argMax(col, ts)`, not "
            f"`anyLast(col)` (observed in ~{_pct(1 - r)} of "
            f"queries that touch a 'latest' column on this cluster)."
        )
    return None


def _bullet_b3(counts: dict[str, int]) -> str | None:
    td = counts.get("uses_todate", 0)
    ts = counts.get("uses_tostartofday", 0)
    r = _ratio(td, td + ts)
    if r is None:
        return None
    if r > DOMINANT:
        return (
            f"**Daily bucket**: `toDate(<time_col>)`, not "
            f"`toStartOfDay()` (observed in ~{_pct(r)} of "
            f"daily aggregations)."
        )
    if r < (1 - DOMINANT):
        return (
            f"**Daily bucket**: `toStartOfDay(<time_col>)`, not "
            f"`toDate()` (observed in ~{_pct(1 - r)} of "
            f"daily aggregations)."
        )
    return None


def _bullet_b4(counts: dict[str, int]) -> str | None:
    star = counts.get("uses_select_star", 0)
    total = counts.get("total", 0)
    r = _ratio(star, total)
    if r is None:
        return None
    if r < SELECT_STAR_NOTE_THRESHOLD:
        return (
            f"**Wide projections**: `SELECT *` appears in only "
            f"~{_pct(r)} of hot queries — name columns explicitly."
        )
    if r > 0.20:
        return (
            f"**Wide projections**: `SELECT *` appears in "
            f"~{_pct(r)} of hot queries; narrow projection "
            f"is preferred but not enforced on this cluster."
        )
    return None


def synthesize(
    counts: dict[str, int],
    top_fact: str,
    tenant_leads_sort_key: bool = True,
    archetypes: set[str] | None = None,
    top_fact_has_anylast_simple_agg: bool = False,
) -> list[str]:
    """Return markdown bullets ready to paste under the
    "From the corpus (mined)" subsection of patterns.md.

    `archetypes` is the set of archetype letters detected by Phase 1.5
    (primary + secondaries). Currently used to apply archetype C's
    hard-suppression of B2 when the top fact has any
    `SimpleAggregateFunction(anyLast, …)` columns.
    """
    archetypes = archetypes or set()
    bullets: list[str] = []

    # B1: filter form.
    b1 = _bullet_b1(counts, top_fact, tenant_leads_sort_key)
    if b1:
        bullets.append(b1)

    # B2: latest-row idiom — with archetype-C override.
    if "C" in archetypes and top_fact_has_anylast_simple_agg:
        # Hard-suppress the corpus-derived bullet, replace with
        # engine-native one. Marker comment for traceability.
        bullets.append(
            "<!-- archetype-C override: anyLast on "
            "SimpleAggregateFunction -->\n  " + _ARCHETYPE_C_B2_REPLACEMENT
        )
    else:
        b2 = _bullet_b2(counts)
        if b2:
            bullets.append(b2)

    # B3: daily bucket.
    b3 = _bullet_b3(counts)
    if b3:
        bullets.append(b3)

    # B4: wide projections.
    b4 = _bullet_b4(counts)
    if b4:
        bullets.append(b4)

    return bullets


def render(bullets: list[str]) -> str:
    """Format bullets as a markdown fragment to paste under the
    'From the corpus (mined)' subheading."""
    if not bullets:
        return (
            "_No dominant form-level conventions observed in the mining "
            "window. Analyst should treat form as free choice unless "
            "engine semantics dictate otherwise._\n"
        )
    return "\n".join(f"- {b}" for b in bullets) + "\n"


if __name__ == "__main__":
    import json
    import sys

    if len(sys.argv) < 3:
        print(
            "usage: synthesize_conventions.py <counts.json> <top_fact> "
            "[--no-tenant-sort-lead] [--archetypes A,B,C,D,E] "
            "[--top-fact-has-anylast-simple-agg]",
            file=sys.stderr,
        )
        sys.exit(2)

    with open(sys.argv[1]) as f:
        data = json.load(f)
    top = sys.argv[2]
    tenant_lead = "--no-tenant-sort-lead" not in sys.argv
    has_anylast_simple = "--top-fact-has-anylast-simple-agg" in sys.argv

    archs: set[str] = set()
    for i, a in enumerate(sys.argv):
        if a == "--archetypes" and i + 1 < len(sys.argv):
            archs = {p.strip().upper() for p in sys.argv[i + 1].split(",")
                     if p.strip()}
            break

    print(render(synthesize(
        data, top,
        tenant_leads_sort_key=tenant_lead,
        archetypes=archs,
        top_fact_has_anylast_simple_agg=has_anylast_simple,
    )))
