## ClickHouse connectivity

Follow the `altinity-expert-clickhouse-connection` skill. In short:

- **MCP mode (preferred):** use a tool whose name contains `clickhouse` and one of `query`/`execute`/`sql` (the exact name depends on the harness, e.g. `clickhouse_execute_query` in OpenCode, `mcp__clickhouse__execute_query` in Claude Code). One SQL statement per call.
- **Exec mode:** `clickhouse-client` with the connection flags the user provided. One statement per invocation; never `--queries-file` or `--multiquery`.

Probe with `select hostName(), version()`.

If the probe fails:
- Stop immediately (do not proceed with audit queries and don't try to write scripts).
- Ask for the missing connection context (target host/cluster, mode, credentials/profile), or return a clear failure.
