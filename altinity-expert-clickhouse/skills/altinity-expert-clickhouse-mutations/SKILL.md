---
name: altinity-expert-clickhouse-mutations
description: Track and diagnose ClickHouse ALTER UPDATE, ALTER DELETE, and other mutation operations. Use for stuck mutations and mutation performance issues.
license: Apache-2.0
---

# Mutation Tracking and Analysis

Track and diagnose ALTER UPDATE, ALTER DELETE, and other mutation operations.

---

## Diagnostics

Run all queries from `checks.sql` in this skill's directory and analyze the results.

---

## Problem Investigation

### Why Is Mutation Stuck?

Check for competing operations using these ad-hoc queries:

```sql
-- Active merges on same table
select
    database,
    table,
    is_mutation,
    elapsed,
    progress,
    num_parts
from system.merges
where database = '{database}' and table = '{table}'
```

```sql
-- Replication queue for same table
select
    type,
    create_time,
    is_currently_executing,
    num_tries,
    last_exception
from system.replication_queue
where database = '{database}' and table = '{table}'
order by create_time
limit 20
```

```sql
-- Part mutations status
select
    name,
    active,
    mutation_version,
    modification_time
from system.parts
where database = '{database}' and table = '{table}'
order by mutation_version desc
limit 30
```

---

## Canceling Mutations

To kill a stuck mutation:

```sql
-- Find mutation_id first
select mutation_id, command from system.mutations
where database = '{database}' and table = '{table}' and not is_done;

-- Then kill it
-- KILL MUTATION WHERE database = '{database}' AND table = '{table}' AND mutation_id = '{mutation_id}';
```

**Warning:** Killed mutations leave table in partially-mutated state.

---

## Best Practices

### Mutation Anti-Patterns

| Anti-Pattern | Problem | Solution |
|-------------|---------|----------|
| Frequent small UPDATEs | Creates many mutations | Batch updates together |
| DELETE without WHERE | Full table rewrite | Use TTL instead |
| UPDATE on high-cardinality column | Slow, lots of IO | Restructure data model |
| Many concurrent mutations | Queue builds up | Serialize mutations |

### Monitoring Mutations

Set alerts for:
- Mutations pending > 10
- Mutation age > 1 hour
- `latest_fail_reason` not empty

---

## Cross-Module Triggers

| Finding | Load Module | Reason |
|---------|-------------|--------|
| Mutation blocked by merge | `altinity-expert-clickhouse-merges` | Merge backlog |
| Mutation OOM | `altinity-expert-clickhouse-memory` | Memory limits |
| Mutation slow due to disk | `altinity-expert-clickhouse-storage` | IO bottleneck |
| Replicated mutation stuck | `altinity-expert-clickhouse-replication` | Replication issues |

---

## Settings Reference

| Setting | Notes |
|---------|-------|
| `mutations_sync` | 0=async, 1=wait current replica, 2=wait all |
| `max_mutations_in_flight` | Max concurrent mutations |
| `number_of_mutations_to_delay` | Delay INSERTs threshold |
| `number_of_mutations_to_throw` | Throw error threshold |
