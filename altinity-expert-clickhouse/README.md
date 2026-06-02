# Altinity Expert ClickHouse Skills

This package contains the modular `altinity-expert-clickhouse-*` ClickHouse diagnostic skills and a dedicated test suite.

## Layout

- `skills/` — all `altinity-expert-clickhouse-*` skill definitions (each has its own `SKILL.md`). The `...-overview` skill is the router and suggests which specialist skill(s) to run next. The `...-security` skill is a standalone, read-only security audit (it uses a `references/` subdirectory loaded on demand) and is not part of the performance-triage chain below.
- `tests/` — test suite and scenarios. Do not modify structure without updating prompts/runner.
- `../releases/` — built zip packages for distribution.

## Manual Test prompts
- Run a quick overview of ClickHouse server health
- Based on findings, run one specialist skill (e.g. memory, merges, replication)
- Full server analysis (runs all skills; can take a long time):

```
Run a comprehensive ClickHouse server analysis and write a single Markdown report to `report.md`.

Workflow:
1) Run `altinity-expert-clickhouse-overview` first and capture the key facts (hostName/version, uptime, disk/memory summary, system.errors, system.*_log activity, system.warnings, log TTL status).
2) Then run ALL specialist skills one-by-one and merge findings into the same `report.md`:
   - altinity-expert-clickhouse-metrics
   - altinity-expert-clickhouse-logs
   - altinity-expert-clickhouse-memory
   - altinity-expert-clickhouse-storage
   - altinity-expert-clickhouse-caches
   - altinity-expert-clickhouse-merges
   - altinity-expert-clickhouse-ingestion
   - altinity-expert-clickhouse-reporting
   - altinity-expert-clickhouse-replication
   - altinity-expert-clickhouse-mutations
   - altinity-expert-clickhouse-dictionaries
   - altinity-expert-clickhouse-schema

Report requirements:
- Use headings per module, and end with a single prioritized action plan (Top 10), each with severity and “why”.
- Include the most important supporting queries (and their results) inline or in appendices.
- If any diagnostic query fails, record it in an “Appendix: Failed Queries” section with the error and the module name.
- Make sure the report clearly states the timeframe used for logs (last 24h unless otherwise specified).
```


## Security Audit (standalone)

The `altinity-expert-clickhouse-security` skill performs a professional, read-only
security audit (users, roles, grants, definer views, row policies, external sources,
audit logs, secrets, Keeper/interserver, encryption/backups, HTTP surface, cluster,
and version-specific behavior). Example prompt:

```
Perform a read-only ClickHouse security audit using the altinity-expert-clickhouse-security skill.
Produce findings with severity, confidence, evidence (redacted), and SQL-only limitations.
```

Run its test with `make test-security` (see below).

## Run Tests

From `altinity-expert-clickhouse/tests`:

```sh
make help

# Default: starts a local ClickHouse in Docker (CLICKHOUSE_VERSION=25.8)
make validate

# Run a single skill test
make test-overview

# Or run everything
make test-all
```

Notes:
- The test runner uses `tests/runner/lib/common.sh` helpers and `CLICKHOUSE_*` env vars for connectivity.
- Provider-specific targets exist in `tests/Makefile` (Codex is the default; Claude is supported; Gemini is a stub).
- Reports are written under `tests/reports/<skill-name>/`.
- For more details (Docker, version switching, SQL-only runs), see `tests/TESTING.md`.

### Running against an external ClickHouse (no Docker)

The test suite still supports pointing at any reachable ClickHouse server:

```sh
export CLICKHOUSE_HOST=<host>
export CLICKHOUSE_PORT=9000
export CLICKHOUSE_USER=default
export CLICKHOUSE_PASSWORD=...     # if set
export CLICKHOUSE_SECURE=0         # or 1 if native TLS

# Disable docker-managed ClickHouse
make validate USE_DOCKER=0

# Example: run a single test
make test-overview USE_DOCKER=0
```

## Build Release Zips

From the repository root:

```sh
make
```

Outputs:
- `releases/<skill-name>.zip`

To list detected skills:

```sh
make list
```
