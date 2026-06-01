---
name: altinity-profiler-clickhouse
license: Apache-2.0
description: |
  Profile a ClickHouse cluster via MCP and emit a per-cluster "analyst" Skill
  the user can save in claude.ai. Activate when the user asks to "profile
  this ClickHouse", "generate an analyst skill", "build a schema guide",
  "map the data in this cluster", or regenerate an existing cluster-analyst
  Skill after schema changes. Works against any ClickHouse with read-only
  SELECT/SHOW/DESCRIBE access via an `execute_query` MCP tool (e.g. the
  Altinity MCP server). Outputs a 5-file markdown bundle plus a README.
---

Your job is to profile the target ClickHouse cluster via the MCP `execute_query` tool, then write out a
per-cluster `<name>-analyst/` folder of 6 markdown files the user will save
as a new Skill (or use to overwrite an existing one).

## Philosophy: knowledge base, not recipe book

The artifact is a **knowledge base** about the cluster — schema, engine
semantics, tenancy model, ingestion graph, observed access patterns,
declared vs. inferred relationships, version quirks — plus a **small set of
engine-level invariants** flagged as Hard Rules (e.g. "FINAL on AggMT is
the read idiom", "filter on `(categoryid, brandid)` first"). The analyst
that consumes this Skill is a competent SQL author; given the right facts,
it composes its own queries. Do not write canned SQL recipes for question
classes. Do write down the engine-level facts the analyst needs to reason
correctly.

A useful test: if a fact disappears from the artifact, would a competent
analyst fail to write a correct query? If yes, the fact belongs. If no
(it's just one of N plausible SQL shapes for the same question), it
doesn't.

## Anti-hallucination: every non-trivial claim must be verified

The profiler emits an artifact saved as a Skill and consumed later. Bad
information compounds. Therefore: **every fact in the artifact must
either be verified by a cluster round-trip at profile time, or marked as
inferred / unverified.** No exceptions. Three claim types, three
verification mechanics:

1. **Existence claims** — table X exists; column Y exists on table X; MV
   Z feeds table X. Verified by `system.tables` / `system.columns` /
   `system.tables.create_table_query`. Cheap. **Hard precondition: a
   table or column name does not appear in the artifact unless it was
   just queried back from `system`.** A fact that fails existence
   verification is dropped, not demoted.

2. **Behavior claims** — this predicate prunes the primary index; FINAL
   on this table amplifies reads ~Nx; this skip index is used; this
   query shape is cheap on the captured tenant. Verified by `EXPLAIN
   indexes=1` and a representative `SELECT … SETTINGS log_queries=1`
   followed by a `system.query_log` lookup keyed on a unique comment
   token. Behavior claims include the captured numbers (`read_rows`,
   granule prune ratio, latency) inline. **A behavior claim with no
   captured measurement must be demoted to "inferred from schema".**

3. **Relationship claims** — table X joins to table Y on key K. Almost
   always inferred on a CH cluster (no real FKs). Profiler verifies (a)
   columns exist on both sides, (b) cardinality on a real tenant slice
   (`matched`, `distinct_left/right`, `avg_fanout`), and records the
   probe artifact alongside the claim. **Every relationship claim is
   marked `[inferred]` regardless of probe outcome** — the probe answers
   "does this join behave 1:1 on the captured tenant", not "is this an
   FK". The analyst is told to re-probe on its own tenant slice.

Demote, do not hard-fail. If a behavior or relationship claim cannot be
verified (parser quirk, no representative tenant available, MCP
timeout), keep the claim in the artifact under an explicit
`inferred:` / `unverified: <reason>` marker. The exception is existence
claims for non-existent tables/columns: those are dropped — a
non-existent referent in the KB is never useful.

## What this Skill produces

A folder `<cluster-name>-analyst/` containing:

```
SKILL.md       — always-loaded entry; at-a-glance, top-15 tables, join map,
                 engine idioms, staleness. ~2-3k words.
catalog.md     — per-table cards for ~15-25 analyst-hot tables. ~2-4k words.
patterns.md    — query-writing priors per hot fact (knowledge, not recipes).
                 ~1-2k words.
pipeline.md    — demoted infra tables, ingestion shape, service users. ~1-2k words.
glossary.md    — naming, users, CH quirks, term decoder. ~0.8-1.5k words.
README.md      — meta: source, decisions, limitations, how to regenerate,
                 verification log (what was checked vs. inferred).
```

Target: ~5k–10k words total (user may pick "concise" or "full" via
questionnaire). The user saves this folder as a Skill (claude.ai Settings → Capabilities, or their agent's skills directory).

## What this Skill is NOT

- Not an ad-hoc query assistant. You are writing a **persistent artifact**.
- Not a live debugger. You don't run `OPTIMIZE`, `ALTER`, `ATTACH`, etc.
- Not a general ClickHouse tutorial, and not a SQL recipe generator.
  The artifact carries **only cluster-specific knowledge** — generic
  engine docs are omitted (the consumer already knows them), and it
  teaches engine-level facts rather than prescribing query shapes for
  question classes (see Philosophy).

## Hard rules (apply always)

1. **Read-only.** Only `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`. Never
   `CREATE`, `ALTER`, `DROP`, `INSERT`, `TRUNCATE`, `OPTIMIZE`, or any
   statement that writes. If the MCP tool allows writes, refuse to use
   that path for this Skill.
2. **PII discipline.** Every query from the target cluster's `query_log`
   must pass through `normalizeQuery()` AND have `/* ... */` comments
   stripped via `replaceRegexpAll(query, '/\\*.*?\\*/', '')` before any
   of its text enters the artifact. Never emit literal values, emails,
   IPs, user IDs, or comment metadata. Use `<tenant>`, `<from>`, `<to>`,
   `<id>` placeholders in example SQL.
3. **Don't fabricate.** If a system table is empty (e.g.
   `system.dictionaries`), if a column doesn't exist in this CH version
   (e.g. `as_select` on CH < 22), or if the query log has no business
   traffic — say so explicitly. Do not invent data or infer beyond what
   the observations support.
4. **Classify by engine, not by database name.** `Dim.X` as
   `ReplicatedReplacingMergeTree` is NOT a Dictionary. The `engine` column
   in `system.tables` is authoritative; DB naming is a hint only.
5. **Infer naming conventions from `engine_full`**, never from name
   patterns. `_local` / `_d` / `dist_` / no-suffix are all cluster-specific
   conventions. Parse `Distributed('<cluster>','<db>','<target>',<shard>)`
   in `engine_full` to map pairs.
6. **Only engines present go in the cheat sheet, and the archetype's
   signature card leads.** If the cluster has no Kafka engine, the
   artifact has no Kafka blurb. If no VersionedCollapsing, no
   aggregation idiom for it. Prune aggressively. Additionally: the
   primary archetype's **signature card** (loaded from
   `archetypes/<primary>.md` after Phase 1.5) is REQUIRED in
   `patterns.md` — it tells the analyst the cluster's overall shape
   before any per-fact card. Engine traps in the artifact come from
   the primary archetype's module first, then any secondaries' trap
   lists merged in.
7. **PREFER Distributed over local for analytics.** Unless the user
   explicitly asks for per-shard diagnostics, the analyst surface is the
   Distributed name (or a wrapping View, depending on the cluster's
   convention).
8. **Verify before asserting (anti-hallucination).** Before any
   non-trivial fact lands in the artifact, run the matching verification
   for its claim type per the "Anti-hallucination" section above
   (existence → drop if absent; behavior → embed captured numbers or
   demote to `inferred from schema`; relationship → mark `[inferred]`
   and attach the cardinality probe). Hallucinated identifiers
   (table/column names that don't exist) are the most damaging failure
   mode — they survive review wrapped in plausible-looking SQL, then
   break at consumer query time. The existence check is cheap; run it
   for every name.
9. **Carry the verification artifact into the bundle.** When a claim was
   verified by query, attach a one-line verification record inline
   (`verified 2026-04-25; read_rows=734,350; query_id=…`). Reviewers can
   tell what was actually tested. The analyst, at read time, sees the
   same evidence and can judge whether today's tenant matches the
   captured shape. Use `inferred:` for schema-only inference and
   `unverified: <reason>` when a planned verification could not run.
10. **Don't restate what the consumer model already knows.** Anthropic's
    Skill best-practices: *"Only add context Claude doesn't already
    have. Challenge each piece of information: 'Does Claude really need
    this explanation?'"* The bundle carries cluster-specific facts
    only — not generic ClickHouse mechanics. Specifically: no FINAL
    semantics prose, no CH error codes (`Code: 43`, etc.), no
    `finalizeAggregation` / `*Merge` internals, no archetype-trap
    explanations beyond a one-sentence cluster-application (full trap
    prose lives in the profiler's `archetypes/<id>.md` modules and is
    NOT copied into per-cluster bundles). Each rule, probe, and
    identifier names one source-of-truth file in the bundle; other
    files cross-reference rather than restate. Files other than
    SKILL.md are loaded lazily — restating a rule across files inflates
    context whenever the analyst question pulls multiple files.

## When to activate

- User asks to profile a ClickHouse cluster or build a schema guide.
- MCP has just connected to a fresh ClickHouse and the user wants a map.
- User asks to regenerate or update an existing `<cluster>-analyst` Skill
  (e.g. after a major schema change).
- User mentions a cluster by name and says "help me query this" — offer to
  profile if no matching analyst Skill is loaded.

## When NOT to activate

- User is asking a one-shot query question against a cluster. Just query.
- User is debugging a specific table. Use MCP directly; don't write a skill.
- Target system is not ClickHouse (PostgreSQL, MySQL, BigQuery, Snowflake).
  This Skill is ClickHouse-specific.

## Pipeline overview (phases 0–8)

```
Phase 0 · Connect and detect shape     → CH version, query_log shape,
                                          Distributed naming
Phase 1 · Discovery (cheap, 5 queries) → cluster topology, DB roster,
                                          engine mix, qlog span
Phase 1.5 · Archetype detect           → assign primary archetype + 0..N
                                          secondaries from Phase 1d/1e
                                          counts; load
                                          `archetypes/<primary>.md` for
                                          phase emphasis
Phase 2 · Questionnaire (1 round)      → DB scope, window, sandboxes,
                                          cluster name, verification tenant
Phase 3 · Catalog                      → per-table metadata for business DBs
Phase 4 · Relations                    → dependency graph + Dictionaries
Phase 5 · Query mining                 → top-50 hot, co-occurrence, hot
                                          columns, representative queries.
                                          Phase 5d.1 form-mining passes
                                          archetypes to the helper for
                                          corpus-override application.
Phase 6 · Demotion                     → split analyst-hot vs pipeline.
                                          Pareto helper takes archetype
                                          for shape-aware thresholds.
Phase 7 · Classification               → Dim/Fact/Mart/Staging/Other
                                          (confident-only)
Phase 7.5 · Verification               → existence checks for every named
                                          identifier; EXPLAIN + log_queries
                                          probe for every behavior claim;
                                          cardinality probe for every
                                          inferred relationship. Captures
                                          numbers that get embedded in the
                                          artifact at phase 8.
Phase 8 · Synthesis                    → write the 6 output files, leading
                                          with the primary archetype's
                                          signature card; merge engine
                                          traps from primary + secondaries;
                                          each claim either carries a
                                          verification record or is marked
                                          `inferred` / `unverified`.
```

Detailed SQL for each phase is in `pipeline.md` (read when you reach phase
execution). Output templates are in `templates.md` (read at phase 8).
Edge-case gotchas are in `edge-cases.md` (read when you hit one).
Archetype modules are in `archetypes/` — load `archetypes/README.md`
once at Phase 1.5 to evaluate the routing rules, then load the
selected primary's full module (and any secondaries' Engine traps +
Corpus-override list) at Phase 8.

## Operating mode

Work sequentially through phases. Don't skip ahead. After phase 1, run
phase 1.5 (archetype routing) immediately — it has no SQL of its own
and uses Phase 1d/1e counts. Mention the assigned primary archetype to
the user as part of the phase-1.5 progress note (it shapes the
artifact). Then pause for phase 2 (questionnaire); after phase 7,
pause to confirm the classification summary before synthesizing.
Between phases, emit short user-facing progress notes — the user
wants to see what you found.

### Progress-notes template

At the end of each phase, emit one concise line to the user:

- `Phase 0: CH <version>, <N>-shard cluster, query_log is <raw|pre-aggregated>.`
- `Phase 1: <N> business DBs, <M> tables, top engines: <list>. Query log <range>, <rows> rows.`
- `Phase 1.5: archetype <primary> (rule <K>: <one-line reason>); secondaries <list-or-none>.`
- `Phase 2: ...` (asking questions)
- `Phase 3: cataloged <N> tables.`
- `Phase 4: <N> dependencies, <M> dictionaries.`
- `Phase 5: top-50 Pareto mined; <K> multi-table queries; <J> tables with hot-column signal.`
- `Phase 6: <X> analyst-hot, <Y> demoted to pipeline.`
- `Phase 7: <A> Fact, <B> Dim, <C> Mart, <D> Staging, <E> Other.`
- `Phase 8: drafting SKILL.md ... then catalog, patterns, pipeline, glossary, README.`

Keep these to one line per phase. User watches progress; don't bury them in
SQL output dumps.

## Connection discipline

Use the MCP `execute_query` tool (or equivalent read-only ClickHouse SQL
tool). On transient errors (network reset, SSL drop, timeout):
- Retry up to 3 times with short backoff.
- If all 3 fail, pause and check with the user (don't abort silently).

Never try to open a different connection path. The MCP tool is the only
allowed channel.

## Regeneration mode

If the user says "regenerate" or "update the <name>-analyst Skill" and
such a Skill is loaded in the current session:

1. Read the loaded Skill's `SKILL.md` frontmatter to get the prior
   `cluster_fingerprint` and `generated_at`.
2. Run phases 0-5 normally.
3. Before phase 6, compute the new fingerprint. If it matches the prior
   one **exactly**, tell the user: "Schema and workload appear unchanged
   since <prior_date>. Regenerate anyway?" If no, stop.
4. If different, proceed through 6-8 as usual. The emitted artifact is a
   complete replacement — the user saves it over the prior Skill.
5. In the new README.md, add a "Since last run" section summarizing what
   changed: new tables, removed tables, engine changes, workload shifts.

If no prior Skill is loaded, regeneration is indistinguishable from
first-run.

## Cluster-name decision

You need a kebab-case cluster name for the output folder. Pick via this
fallback chain:

1. `SELECT cluster, count() FROM system.clusters GROUP BY cluster` —
   pick the distinctive one, skipping `default`, `all-*`, `test_*`,
   `parallel_replicas`, `replicated`, `clickhouse`, `local`, `prod`
   (these are generic macros, not business identifiers).
2. If none distinctive: Kafka broker hostname from `engine_full` of
   Kafka engines (e.g., `prod-noncde-kafka.razorpay.com` → `razorpay`).
3. If no Kafka: dominant business-database name (e.g., `hockeystack`,
   `divinity`).
4. If none of the above is distinctive: ask the user in phase 2.

Normalize: lowercase, ASCII, kebab-case. Strip `_cluster`, `_replicated`,
`_sharded` suffixes. Append `-analyst`. If the name collides with a
Skill already loaded in the session, append `-2`, `-3`, etc.

## Shape detection (phase 0 outputs drive everything downstream)

Before any mining, detect three axes of variation. See `pipeline.md`
(Phase 0) for the exact SQL:

- **CH version bucket** (< 22 / 22-23 / ≥ 24): selects SQL templates
  per phase (e.g., `as_select` column vs `create_table_query` regex
  fallback).
- **Query log shape** (raw vs pre-aggregated). If columns are wrapped
  as `any(...)` / `count()` / `sum(query_duration_ms)`, the log is
  pre-aggregated (audit corpus). If columns are flat (`tables`,
  `columns`, `query_kind`), it's raw (live cluster).
- **Distributed convention**. Parse `engine_full` of Distributed engines
  to discover the local-naming pattern and shard keys.

Record these in a "shape profile" you'll reference throughout. Emit them
to the user in the phase-0 progress note.

## Questionnaire (phase 2) — the one interactive moment

After phase 1, present a compact preview and ask ≤5 targeted questions.
Sample preview:

```
Phase 1 summary:
- ClickHouse <version>, cluster <cluster-name>, <topology>
- <N> business DBs: <top-5 by table count>
- <M> user sandboxes candidates (heuristic): <list-if-any>
- Query log: <from>..<to>, <rows> rows
- Engine mix: <top-5 by count>
```

Then ask (combine as few questions as possible):

1. **Database scope**: "Phase 1b found <N> business DBs (<top-5 with
   table counts>). Which should be in scope for deep mining? Default:
   all <N> non-system, non-sandbox. Common narrowings: a single tenant
   DB, one product line, exclude archived/legacy DBs. Always excluded:
   `system`, `information_schema`, `_temporary_and_external_tables`."
   This answer feeds Phase 3's `database IN (:included)` filter and
   Phase 5a's workload-shape window — narrowing here saves the most
   downstream work. Show the table-count column so the user can see
   where the volume actually lives.
2. **Sandboxes** (only if heuristic found any): "Skip flagged sandboxes?"
3. **Query-log window**: default to last 7 days if available, else the full log.
4. **Service users** (only if obvious): "Treat `<list>` as service accounts?"
5. **Cluster name** (only if name-fallback was unclear): "I'll name the
   artifact `<candidate>-analyst`. Override?"
6. **Detail level**: "Target ~5k words (concise) or ~10k words (full)?"
7. **Verification tenant** (REQUIRED): "I'll run behavior probes
   (EXPLAIN + a small SELECT) and cardinality probes against a real
   tenant to capture `read_rows`, granule prune, and join fanout
   numbers. Which tenant slice should I use?" — pick a tenant with
   non-trivial data volume in the last 7 days. State that the probes
   are read-only `SELECT` queries with `LIMIT` clauses; no modification.

If the user declines a verification tenant, behavior and relationship
claims will all be marked `inferred from schema` rather than carrying
captured numbers — proceed but warn that the artifact's evidence layer
will be thinner.

Do not ask blind. Every question must reference concrete findings from
phase 1. If phase 1 is entirely unambiguous on a given dimension, skip
that question and state your assumption in the phase-2 progress note.

## Success criteria

A good artifact:

- Opens with a 2-sentence orientation an analyst can act on immediately.
- Names the top ~15 tables with engine + key + row estimate in one
  scannable table in SKILL.md.
- Teaches the cluster's non-obvious rules prominently (Distributed
  naming, tenant scoping requirement, aggregation idiom, etc.) as a
  small set of Hard Rules — each a single engine-level invariant, not a
  SQL recipe.
- Has engine idioms scoped to engines actually present.
- Gives per-fact knowledge cards (time column, measures, dimensions,
  enrichment shape, declared vs. inferred relationships) **without
  canned SQL recipes for question classes**. Templates are fine for
  illustrating shape; prescriptions for "the answer to question X is
  this query" are not.
- Satisfies the verification contract (above): every named identifier
  checked against `system.tables`/`system.columns` (no hallucinations);
  every behavior claim carries a captured measurement (`read_rows`,
  `granules_prune_pct`, `query_id`, `verified_at`) or an `inferred from
  schema` marker; every JOIN is `[inferred]` with its cardinality probe.
- README's verification log lists what was checked vs. inferred.
- Explicitly lists demoted infra tables in pipeline.md.
- Flags limitations honestly (thin query log, empty `system.dictionaries`,
  dependencies_* sparsely populated, etc.).

A bad artifact:

- Enumerates 500 tables. (Use the Pareto; long tail gets DESCRIBE.)
- Has generic ClickHouse docs copy-pasted in.
- Has engine idioms for engines not present.
- Has hallucinated Dictionary attributes when `system.dictionaries` was
  empty.
- Violates the verification contract (above): names a non-existent
  identifier (e.g. joins `spatialrss.authors` when the real table is
  `mstuserinformation_new` — the worst failure mode, surviving to
  consumer-query time as silent errors), asserts a JOIN without an
  `[inferred]` marker, or makes a behavior claim with neither a captured
  measurement nor an `inferred from schema` marker.
- Reads as a SQL recipe book — "for question X, write query Y" — rather
  than a knowledge base the analyst reasons over.
- Is indistinguishable from a prior cluster's artifact.

## Error handling

- **Target cluster unreachable** (MCP tool errors consistently): abort
  after 3 retries. Report to user. Do not partial-write files.
- **Empty business DB result** (phase 1 returns only system DBs): ask the
  user whether the filter is correct; do not assume the cluster is empty.
- **Query log has zero rows in the window**: fall back to catalog-only
  mode. Emit `patterns.md` with "patterns inferred from schema; no
  observed workload" caveat prominently.
- **`DESCRIBE system.query_log` fails**: the cluster may have query_log
  disabled. Switch to catalog-only; note in README.md.
- **Target cluster is not ClickHouse**: abort. This Skill is
  ClickHouse-specific.
- **User cancels mid-pipeline**: save progress notes you've emitted so
  far; do not write any artifact files on partial runs.

## Output location

Write files to a folder named `<cluster>-analyst/` in a location the user
has write access to. Ask in phase 2 if unsure (default: prompt the user).
The user is expected to zip or copy the folder and install it as a new
Skill — in claude.ai via Settings → Capabilities, or by placing it in
their agent's skills directory (e.g. Claude Code / Codex).

## When you're done

End with a short summary:

```
Wrote <cluster>-analyst/ (6 files, <N> words total). To save as a
Skill: compress the folder and add it to your agent — claude.ai
Settings → Capabilities → Add Skill, or your skills directory.
```

If the user already had a matching analyst Skill loaded, add:

```
This artifact is a full replacement for the previously loaded
<cluster>-analyst Skill (generated <prior_date>). Re-upload to update.
```

## Reference files

Load these on demand. Do not load all at once.

- **`pipeline.md`** (in this Skill) — full SQL recipes for each of the
  all phases (0–8). Load at phase start. ~9-11k words.
- **`templates.md`** (in this Skill) — section templates for each of the
  6 output files. Load at phase 8. ~10-12k words.
- **`edge-cases.md`** (in this Skill) — gotcha library (~27 known edge
  cases). Load when you hit a suspected edge case, or scan once at
  pipeline start if the cluster shape feels unusual. ~5-6k words.
- **`archetypes/README.md`** — index + first-match-wins decision rules
  for archetype routing. Load at Phase 1.5. ~1.5k words.
- **`archetypes/<primary>.md`** — the selected archetype's full module
  (signature card, phase emphasis, engine traps, corpus-override
  list). Load after Phase 1.5 assigns the primary, and re-consult at
  Phase 5d.1 (passing `--archetypes` to `synthesize_conventions.py`)
  and at Phase 8 (rendering the signature card and engine-trap
  sections). ~1-2k words each.
- **`archetypes/<secondary>.md`** — any secondary archetypes' Engine
  traps + Corpus-override list sections only. Load at Phase 8 when
  hybrid signals fired in Phase 1.5.

## Style for the artifact you emit

- Second-person / imperative, never first-person. "Always filter X
  first." Not "I'd recommend…"
- Concrete examples over prose. Tables where tables work; code fences
  for SQL shapes; prose for ingestion-flow explanations.
- No adjectives of emphasis ("huge", "critical", "beautiful",
  "amazing"). Just state. "4.05B rows" not "a huge 4.05B rows".
- Every uncertain claim must be labeled: "inferred from schema", "not
  observed in query log", "Likely" (classification confidence).
- No emojis. Monospace `backticks` for identifiers.

## One final rule

If anything in a phase is unclear to you — if the SQL result is
unexpected, if an engine you've never seen appears, if the user's
questionnaire answer contradicts discovery — **stop and check with the
user** rather than guess. The artifact will be saved and consumed later;
bad information compounds.
