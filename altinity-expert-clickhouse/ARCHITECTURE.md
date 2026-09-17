# Architecture: `altinity-expert-clickhouse` Skill Set

This document describes how the ClickHouse diagnostic skills in this repo are organized, how to avoid duplication, and how to evolve the set safely.

## Goals

- **Fast triage**: each skill should be runnable independently and quickly surface the likely class of problem.
- **Clear ownership**: each diagnostic “signal” has a canonical home to prevent drift and repeated maintenance.
- **Controlled overlap**: some duplication is allowed for UX, but it must be bounded and intentional.
- **Safe-by-default queries**: avoid unbounded reads of large system log tables; use time windows and limits.

## Design Principles

### 0) Start with connection + overview

Recommended default workflow:

1) Run **`altinity-expert-clickhouse-connection`** to establish connection mode, `{cluster}` value, and a default log timeframe.
2) Run **`altinity-expert-clickhouse-overview`** for a quick health snapshot and routing.
3) Follow routing rules into specialized skills (replication/memory/storage/merges/ingestion/part-log/mutations/etc.).

### 1) Canonical owners + bounded overlap

Some system tables (notably `system.part_log`) are cross-cutting signals for many incident types. To keep the set maintainable:

- Each signal has a **canonical owner skill** where the full query pack + interpretation lives.
- Other skills may include a **small triage subset** of shared signals to reduce hops.
- If a query belongs to a canonical owner, other skills should **point to** that skill rather than copy/paste more queries.

### 2) `part_log` is cross-cutting; treat it as “secondary” in ingestion

`altinity-expert-clickhouse-ingestion` is **insert/query-centric**. `system.part_log` checks in ingestion are **secondary triage** only (micro-batching and merge pressure indicators).

### 3) Overlap rule: N=2 for `system.part_log` in non-canonical skills

To prevent repetitive operations across the skill set:

- Any non-canonical skill may contain **at most 2** `system.part_log`-based checks.
- Those checks must be framed as **triage**: “if this lights up, run the canonical owner skill”.

This keeps UX good while ensuring deeper `part_log` analysis is maintained in one place.

### 4) Cluster-wide defaults where appropriate

Where the signal can vary by replica (replication, per-host queue/exceptions), prefer:

- `clusterAllReplicas('{cluster}', …)` and include `hostName()` in output.

Use `'{cluster}'` placeholders consistently (DataGrip-friendly). If a query pack is single-host by design, state that explicitly in the skill.

### 4.1) Cluster macro and substitution rule

- Always probe for a configured macro: `SELECT getMacro('cluster') AS cluster;`
- If it succeeds: treat that macro value as the source of truth for the node and **do not** perform any substitution.
- If it fails (macro missing/error): ask the user which `system.clusters.cluster` value to use, then substitute into `'{cluster}'` placeholders in query packs.

### 5) Default timeframes are relative unless user specifies a window

Queries should default to “last 1h/6h/24h/7d” style windows. Only switch to explicit timestamps when the user provides them in the prompt.

## Canonical Ownership Map

## Foundation and orchestration skills

### `altinity-expert-clickhouse-connection`

This is a **foundation** skill (not a diagnostic owner).

It standardizes:

- Connection mode (MCP preferred; `clickhouse-client` fallback)
- `{cluster}` selection for `clusterAllReplicas('{cluster}', …)` query packs
- Default log timeframe (24h unless the user provides a window)
- What context must be carried forward between skills (mode/cluster/timeframe)

Guideline: any ClickHouse diagnostic flow should run this first (or at least confirm the same outputs: mode, `{cluster}`, timeframe).

### `altinity-expert-clickhouse-overview`

This is the **front door** / router skill (not a canonical owner of any deep signal).

It should remain:

- Fast and low-risk (aggregations, counts, small result sets)
- Opinionated only enough to route (severity labels and “what to run next”)
- Focused on “is the server healthy?” rather than “deep dive root cause”

Triage placement guidance:

- Keep cross-cutting, high-level checks here (memory/disk saturation, active parts, replication lag metrics, background pool saturation, log TTL presence, recent error rates).
- Do **not** grow detailed `system.part_log` timelines here; `part_log` deep analysis belongs to `altinity-expert-clickhouse-part-log` and domain skills (with bounded overlap).

### `altinity-expert-clickhouse-part-log`

**Canonical owner for part activity**:

- micro-batching (`NewPart` rate, small parts)
- insert/merge balance (`NewPart` vs `MergeParts`)
- merge latency distributions (p50/p95/max)
- mutation storms (`MutatePart` rate)
- replication churn symptoms at part layer (`DownloadPart`)
- cleanup spikes (`RemovePart`) and moves (`MovePart`)
- `part_log` errors

Other skills should not “grow” additional `part_log` analytics beyond the allowed triage N=2.

### `altinity-expert-clickhouse-ingestion`

**Canonical owner for insert/query signals**:

- current inserts (`system.processes`)
- insert performance and failures (`system.query_log`)
- batch size analysis (`written_rows`)
- MV overhead (`system.query_views_log`)
- ingestion topology checks (Kafka/Buffer engines)
- insert-related settings

Allowed `part_log` triage (N=2):
- micro-batching: `NewPart` rate by table
- merge pressure: insert vs merge balance

### `altinity-expert-clickhouse-merges`

**Canonical owner for merge-engine state**:

- current merges (`system.merges`)
- part counts / partitions (`system.parts`)
- merge_tree settings (`system.merge_tree_settings`)

Allowed `part_log` triage (N=2):
- slow merges (top by `duration_ms`)
- failed merges (`error != 0`)

### `altinity-expert-clickhouse-mutations`

**Canonical owner for mutation control-plane**:

- mutation backlog/age/failures (`system.mutations`)
- “running now” mutations (`system.merges WHERE is_mutation=1`)
- background pool saturation metrics (`system.metrics` Background*)
- mutation types / creation rate

Allowed `part_log` triage (N=2):
- failed `MutatePart` (`error != 0`)
- mutation performance summary by table

Mutation storm detection (rates/timelines) belongs to the `part-log` skill.

### `altinity-expert-clickhouse-replication`

**Canonical owner for replication/Keeper**:

- replica health (`system.replicas`)
- queue and errors (`system.replication_queue`)
- fetches / lag investigation
- `NO_REPLICA_HAS_PART` workflow
- Keeper/ZooKeeper connectivity and latency

## Practical Maintenance Guidelines

### When adding a new query, decide its “home” first

Use this rule-of-thumb:

- “How many parts/events per unit time?” → `part-log`
- “Why are inserts slow/failing, which user/query?” → `ingestion`
- “Are merges stuck/slow, too many parts?” → `merges`
- “Which mutation is stuck and why?” → `mutations`
- “Why replicas can’t fetch/merge parts, Keeper load?” → `replication`

### Keep query packs safe

- Always time-bound system log tables (`*_log`) and `system.part_log`.
- Always `LIMIT` and prefer aggregated outputs.
- If schema differs across versions, use the “schema-safe rule”: `DESCRIBE TABLE system.<table>` and remove only missing columns.

### Cross-module triggers are preferred over duplication

If your skill detects a condition owned by another module, add a short “trigger → run skill X” note instead of copying more queries.

## Cluster-wide policy (for subsequent development)

New and updated skills should operate **cluster-wide by default** in the same way as replication/part-log:

- Prefer `clusterAllReplicas('{cluster}', system.<table>)` for queries where per-replica divergence matters.
- Include `hostName() AS host` and group by `host` when aggregating.
- Keep `{cluster}` as a placeholder in `.sql` files and rely on the connection skill’s cluster macro/substitution rule.

Exceptions (avoid duplicate work):

- For tables that are effectively identical across replicas (example: `system.distributed_ddl_queue`), prefer querying a single node (local `system.*`) or a non-replica fanout (e.g., `cluster('{cluster}', …)`) to avoid duplicated rows.

Single-node mode:

- Do not detect “single node” by `system.clusters` being empty (many installs define a `default` cluster even on one node).
- If there is exactly one configured cluster and it is local-only (one endpoint and `is_local=1`), run in **local mode** by automatically rewriting `clusterAllReplicas('{cluster}', system.<table>)` → `system.<table>` before execution.

## Skill file conventions (added 2026-09)

All 19 skills follow `SKILL_TEMPLATE.md` in this directory: identical "How to run the
query packs" and "Report format" sections, skill-specific "Interpretation rules",
explicit "Next skills" routing (`load skill altinity-expert-clickhouse-<name>`), and
optional `reference.md` for background material that a model should read only when it
needs to explain a recommendation. The template exists so that mid-size models execute
every skill the same way; do not add generic ClickHouse knowledge to SKILL.md.

Query pack statements carry machine-readable headers:

```sql
-- @check merges-04 Merge success/failure trend by hour (24h)
-- @requires table:system.part_log
SELECT ... ;
```

- `@check <id> <title>`: stable id reported back in findings.
- `@requires table:system.X | keeper | version>=X.Y | version<X.Y | kafka`: skip the
  statement when unmet instead of failing. Version-gated alternatives of the same check
  share the id (used for the 26.8 `key_values` async-metric layout change).
- `@skip-matrix <reason>`: multi-step session recipes the matrix must not run.

Every check that can be graded returns a `severity` column (`Critical`, `Major`,
`Moderate`, `Minor`, `OK`) so the model copies verdicts instead of inventing them.

### Testing layers

1. `tests/sql-matrix/`: `make matrix-up sql-matrix` runs every statement of every pack
   against ClickHouse 24.8, 25.8 and 26.8 containers configured as a one-node replicated
   cluster with embedded Keeper (`tests/clickhouse-server/config.d/cluster-keeper.xml`)
   and all optional logs enabled. Any error not covered by `@requires` fails the run.
2. `tests/<skill>/`: scenario fixtures (`dbschema.sql`, `scenarios/`) and `expected.md`.
3. `tests/opencode/`: `run_suite.sh` runs the model under test (OpenCode, read-only
   agent, temperature 0) in arms `none` / `old` / `new` and scores tool behaviour and
   report content deterministically (`assert_run.py`). Use it to prove a skill change
   helps the model rather than only adding context.
