# Archetype E · Streaming + Federation

## When loaded

Selected by rule 3 (Kafka-streaming: `kafka_n > 15` OR (`null_n > 20`
AND `mv_share > 0.10`)) or rule 4 (federation: `external_n > 30` OR
`external_n / biz_tabs > 0.30`). The cluster either ingests via
Kafka (`Kafka` → optional `Null` landing pad → `MaterializedView` →
target storage) or reads through external engines (`MySQL`,
`PostgreSQL`, `URL`, `S3`, `S3Queue`, `HDFS`, `MongoDB`, `Redis`).
Data is in motion or lives elsewhere.

## Signature card

Lead `patterns.md` "Cluster-wide writing conventions" → "From the
schema (derived)" with the **external-engine banner** card:

```markdown
## Cluster shape — streaming / federation

Some tables on this cluster are **not storage** in the usual sense.
They are streaming endpoints (Kafka topics, Null landing pads) or
live windows onto external systems (MySQL, PostgreSQL, URL, S3).
Naming a table here doesn't mean reading from it is safe or even
defined.

Read priorities:
- **NEVER `SELECT` from a `Kafka` engine table**. The select
  consumes messages and advances the consumer group's offset —
  every analyst query that touches a Kafka engine permanently moves
  the read pointer for production downstream consumers. The
  artifact MUST mark all `Kafka` engines as forbidden in
  `pipeline.md` and surface them with red flags in `catalog.md` if
  they accidentally land there.
- **`Null` engine is a fan-out landing pad, not storage**. Inserts
  trigger any MVs that read from it; the row is then dropped.
  Reading returns no rows. Document in `pipeline.md`; do not
  surface as analyst-hot.
- **External engines query the remote system per `SELECT`**.
  `MySQL`, `PostgreSQL`, `URL`, `S3` engines have no local index, no
  partition pruning, and no caching by default. A query against
  one of these is a live request to the remote — slow, network-
  bounded, and prone to remote-side rate limits. Surface this in
  the engine's catalog card with a "remote read" banner.
- **Ingestion shape diagram is mandatory**. The artifact's
  `pipeline.md` must contain a Kafka → MV → target diagram for any
  Kafka chain present, plus a fed-source list for any external
  engines. Without these, the analyst can't tell which tables are
  storage versus motion.
```

## Phase emphasis

- **Phase 5f (streaming-specific mining)**: mandatory. Parse every
  `Kafka` engine's `engine_full` (or `create_table_query` regex
  fallback for the CH 23.x codec bug) for `kafka_topic_list`,
  `kafka_group_name`, `kafka_broker_list`. Build the
  `Kafka topic → Kafka engine table → [Null pad →] MV → target`
  ingestion chain.
- **Phase 6 (Pareto demotion)**: every `Kafka` engine table gets
  demoted automatically (engine-by-nature). Same for `Null`. They
  appear in `pipeline.md`'s "Streaming infra" subsection, never in
  `catalog.md`.
- **Phase 7 (classification)**: `Kafka`, `Null`, and external
  engines are NOT facts/dims/marts. They get their own role:
  `Streaming` for Kafka/Null, `External` for MySQL/PG/URL/S3.
  These don't appear in the analyst-hot top-N.
- **Phase 8 (synthesis)**: the artifact must contain the
  external-engine banner card before the engine idioms section.
  This is non-negotiable for E primary; for E secondary (e.g. C
  primary + E secondary on a Kafka-fed cube), the banner appears
  as a sub-section under the C signature card.

## Engine traps

- `[trap-E1] SELECT from Kafka advances the consumer group offset`.
  Production consumers downstream lose messages permanently. There
  is no read-only mode for Kafka engines. The artifact MUST flag
  every Kafka engine as forbidden-to-select in both `catalog.md`
  (if it accidentally surfaces there) and `pipeline.md` (where it
  belongs).
- `[trap-E2] Null engine reads return no rows`. Inserts trigger
  MVs reading FROM the Null table; the inserted row is then
  dropped. Querying a Null engine is always empty.
- `[trap-E3] External engine reads have no partition pruning`.
  `MySQL`, `PostgreSQL`, `URL`, `S3`, `MongoDB`, `Redis` engines
  push the WHERE clause to the remote system at best (and often
  not at all). Latency, throughput, and rate-limit are all
  remote-side concerns; a `SELECT * FROM <mysql_engine>` reads the
  full remote table.
- `[trap-E4] S3Queue is consume-once`. Like Kafka, `S3Queue` reads
  advance an offset. Querying it directly is destructive.
- `[trap-E5] Kafka MV without Null intermediate`. When a Kafka
  engine is the direct source of an MV, the MV's SELECT runs on
  every batch and the parsed rows go directly to the target. There
  is no buffering — backpressure is "drop or die." The cluster
  owner usually adds a Null engine in front to fan out to multiple
  MVs without re-reading Kafka. Surface the topology choice if
  observed.
- `[trap-E6] CH 23.x engine_full codec bug on Kafka tables`.
  `SELECT engine_full FROM system.tables WHERE engine='Kafka'`
  fails with `unexpected value 111 for boolean`. Fall back to
  `substring(create_table_query, 1, 500)` and regex-extract the
  Kafka settings keys.

## Corpus-override list

E rarely produces analyst-facing facts of its own — Kafka and Null
don't get queried, external engines are slow and rare. When E is
**primary**, the corpus-mined bullets often have very little signal
(few hot queries on engines that aren't external). Default to
silence over invention.

| Bullet ID | Action | Replacement |
|---|---|---|
| `B1-prewhere` | Pass through if any non-streaming fact is hot. Suppress otherwise. | (corpus-derived) |
| `B2-anylast-vs-argmax` | Pass through if any AggMT is hot; suppress otherwise. | (corpus-derived) |
| `B3-todate-vs-tostartofday` | Pass through. | (corpus-derived) |
| `B4-select-star` | Pass through. | (corpus-derived) |

When E is a **secondary** (e.g. C primary + E secondary), only the
trap list above merges in — the corpus-override behavior is C's. The
banner card stays as a sub-section under C's signature card.
