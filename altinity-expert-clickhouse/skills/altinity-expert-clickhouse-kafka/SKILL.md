---
name: altinity-expert-clickhouse-kafka
description: Diagnose ClickHouse Kafka engine health, stuck consumers, thread pool capacity, consumer lag, slow materialized views, and Kafka rack-awareness or cross-AZ traffic. Use for Kafka lag, consumer errors, rebalances, thread starvation, or unexpected cross-AZ Kafka cost.
license: Apache-2.0
---

# Kafka engine health

Answers "are the Kafka consumers polling, committing and keeping up, and is anything starving them?" from `system.kafka_consumers`, `system.metric_log`, `system.query_views_log` and `system.text_log`.
Run `altinity-expert-clickhouse-connection` first if the connection mode, cluster and time window are not yet established.

## Query packs

- `checks.sql` — 7 checks: consumption health per consumer (kafka-01), average rows per commit (kafka-02), rebalances and assignments (kafka-03), consumers versus message broker pool size (kafka-04), pool utilization over 12 hours (kafka-05, needs `system.metric_log`), slow materialized views on Kafka tables (kafka-06, needs `system.query_views_log`), Kafka messages in the log (kafka-07, needs `system.text_log`).
- `advanced_checks.sql` — 4 checks: consumer exception drill-down for one table (needs `{db}` and `{kafka_table}`), total lag per table, lag per partition, broker connection health. The last three parse `rdkafka_stat`. The file also contains a three-statement consumption-speed recipe marked `@skip-matrix`: it creates a temporary table, sleeps, then compares snapshots, so all three statements must run in ONE `clickhouse-client` session. It cannot run over MCP or as separate `--query` calls.
- `troubleshooting.md` — common Kafka errors and configuration fixes (ACL errors, poll interval, dead letter queue, offset rewind, parallel consumption tuning).
- `references/rack-awareness.md` — cross-AZ and `client.rack` investigation; load it when the question involves AWS MSK, `KAFKA_CLIENT_RACK`, cross-AZ cost, VPC endpoints, or a Kafka cluster migration.
- `reference.md` — background (Kafka engine and librdkafka settings); read only when you need to explain a recommendation.

## How to run the query packs

1. Read each pack file from this skill's directory (the skill loader prints the directory path).
2. Run statements one at a time, never a whole file. Statements end with `;` and start with a `-- @check <id> <title>` header; keep the id with its result.
3. Honor `-- @requires`: skip the statement when the named table is missing, when `keeper` is required and the server has no Keeper/ZooKeeper, or when the version condition is not met. List skipped ids with the reason.
4. Keep `{cluster}` as written when a cluster macro exists; otherwise apply the connection skill's rewrite rule. Any other `{placeholder}` is a template variable: substitute a real value first or skip the statement.
5. On an error, record the check id and the first line of the error, then continue. Only for `UNKNOWN_IDENTIFIER`, run `DESCRIBE TABLE system.<table>` and drop the missing column.
6. A `severity` column is the verdict for that row. Copy it; do not re-grade.

## Interpretation rules

- A consumer is stuck when `last_exception_time >= last_poll_time` or `last_exception_time >= last_commit_time`: it is failing rather than progressing. Otherwise treat it as healthy even if lag exists.
- `exceptions` is a tuple of arrays with matching indices. `exceptions.time[-1]` and `exceptions.text[-1]` are the most recent error; quote both.
- `kafka_consumers > mb_pool_size` (kafka-04) is thread starvation: consumers wait for a free thread. Fix by raising `background_message_broker_schedule_pool_size` (default 16). Size it as the total of all Kafka, RabbitMQ and NATS consumers plus 25 percent.
- Materialized view average duration above 30 seconds (kafka-06) risks exceeding `max.poll.interval.ms`, which gets the consumer kicked from the group. Errored view executions are usually the rebalance interrupting a batch mid-flight, not an independent bug.
- The most common cause of a slow view on a Kafka table is several `JSONExtract` calls re-parsing the same JSON blob. The fix is one-pass `JSONExtract(json, 'Tuple(...)')` plus `tupleElement()`; see `troubleshooting.md` in this directory.
- Pool utilization over 12 hours (kafka-05): values sustained near the pool size mean capacity pressure; spikes that line up with lag mean temporary overload; a flat zero means the consumers are not running at all, which is a different finding from lag.
- `rdkafka_stat` is empty unless `<statistics_interval_ms>` is set in the Kafka engine config. If it is empty, report the three lag and broker checks as skipped for a missing prerequisite, not as OK.
- `client.rack` alone changes nothing: the brokers must run `RackAwareReplicaSelector`, which is not the default. Verify the broker-side selector before recommending any rack setting.
- In librdkafka broker counters, `tx` and `rx` are request and response counts while `txbytes` and `rxbytes` are bytes. Attribute per-broker and cross-AZ traffic from the byte counters only.

## Report format

1. **Header**: connection mode, cluster or "single node", ClickHouse version, time window.
2. **Findings**: table with columns `check`, `severity`, `object`, `evidence`, `recommendation`; one row per finding, Critical first. Evidence quotes the numbers from the result rows.
3. **OK checks**: one line listing the check ids that returned no problem rows.
4. **Skipped and failed checks**: id and reason or first error line. Never omit this section.
5. **Next steps**: skills to load next and immediate actions.

## Next skills

- Materialized view inserts are the bottleneck, or insert latency dominates → load skill `altinity-expert-clickhouse-ingestion`
- High merge memory or a part backlog on the destination table → load skill `altinity-expert-clickhouse-merges`
- The view query itself is slow independent of Kafka → load skill `altinity-expert-clickhouse-reporting`
- The destination table design or the view chain looks wrong → load skill `altinity-expert-clickhouse-schema`
- Cross-AZ cost remains after the Kafka checks, or the traffic uses ClickHouse interserver ports → load skill `altinity-expert-clickhouse-replication`
- Message broker pool saturation needs a longer trend than 12 hours → load skill `altinity-expert-clickhouse-metrics`
