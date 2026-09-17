# Kafka reference

Background material for `altinity-expert-clickhouse-kafka`. Read only when you
need to explain or justify a recommendation.

## Settings

| Setting | Scope | Notes |
|---|---|---|
| `background_message_broker_schedule_pool_size` | Server | Thread pool shared by Kafka, RabbitMQ and NATS consumers (default 16) |
| `kafka_num_consumers` | Table | Parallel consumers for one table, bounded by available cores |
| `kafka_thread_per_consumer` | Table | Must be 1 for the consumers of a table to insert in parallel |
| `kafka_handle_error_mode` | Table | `stream` on 21.6+, `dead_letter` on 25.8+ |
| `kafka_max_block_size` | Table | Rows flushed per insert; larger blocks mean fewer, bigger parts |
| `kafka_poll_max_batch_size` | Table | Messages per poll call |
| `max_poll_interval_ms` | librdkafka | Maximum time between polls before the broker evicts the consumer (default 300000) |
| `statistics_interval_ms` | librdkafka | Enables the `rdkafka_stat` column; collection is off by default |
| `client.rack` | librdkafka | Consumer rack id, only effective when brokers use `RackAwareReplicaSelector` |

## Pool sizing

One consumer occupies one thread in the message broker pool while it polls.
Size the pool as the sum of `kafka_num_consumers` over all Kafka tables, plus
RabbitMQ and NATS consumers, plus roughly 25 percent headroom. A pool that is
exactly the consumer count leaves nothing for retries and rebalances.

## Where the numbers come from

- `system.kafka_consumers` is a live snapshot per consumer, not a log. It has no
  history, so rates require two snapshots (the recipe in `advanced_checks.sql`).
- `rdkafka_stat` is a JSON string produced by librdkafka itself. Its
  `consumer_lag` of -1 means "unknown", usually because the partition has not
  been polled yet; filter those rows out before summing lag.
- `system.query_views_log` records materialized view executions triggered by the
  Kafka insert, which is where slow view logic shows up.
