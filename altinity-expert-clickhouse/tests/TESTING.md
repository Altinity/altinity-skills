# Testing: `altinity-expert-clickhouse` Skills

This test suite is scenario-driven:
- Each skill has a test directory under `tests/<skill>/` with `dbschema.sql`, optional `scenarios/*.sql`, `prompt.md`, and `expected.md`.
- `tests/runner/run-test.sh` sets up a dedicated DB, runs scenario SQL, generates a Markdown report via an LLM (optional), and optionally verifies the report against `expected.md` via an LLM.

## Prerequisites

- `clickhouse-client` installed and able to connect to your target ClickHouse using `CLICKHOUSE_*` env vars.
- `jq` (recommended) for parsing verification output.
- One of:
  - `codex` CLI (default `LLM_PROVIDER=codex`)
  - `claude` CLI (`LLM_PROVIDER=claude`)

## Quick Smoke Checks

```bash
cd altinity-expert-clickhouse/tests

# Start a test ClickHouse in Docker (default image tag is `CLICKHOUSE_VERSION=25.8`)
make up

# Syntax checks
bash -n runner/run-test.sh runner/verify-report.sh runner/lib/common.sh

# Connection check (uses CLICKHOUSE_* env vars; see below)
make validate

# SQL-only run (no LLM, no verification)
make test-overview RUNNER_FLAGS=--skip-llm

# Full suite (SQL-only)
make test RUNNER_FLAGS=--skip-llm
```

### Running different ClickHouse versions

```bash
cd altinity-expert-clickhouse/tests
make reset CLICKHOUSE_VERSION=24.12
make test-overview RUNNER_FLAGS=--skip-llm CLICKHOUSE_VERSION=24.12
```

### Connection environment variables

`tests/runner/lib/common.sh` uses:
- `CLICKHOUSE_HOST` (defaults to `arm` if unset)
- `CLICKHOUSE_PORT` (default `9000`)
- `CLICKHOUSE_USER` (default `default`)
- `CLICKHOUSE_PASSWORD` (optional)
- `CLICKHOUSE_SECURE` (`true|1|yes|on` enables `--secure`)

## LLM Provider Examples

```bash
cd altinity-expert-clickhouse/tests

# Run with Claude
make test-overview LLM_PROVIDER=claude

# Pick Codex models (optional)
make test-overview LLM_PROVIDER=codex CODEX_MODEL=gpt-5.2-codex-mini CODEX_VERIFY_MODEL=gpt-5.2-codex-mini
```

Note: `LLM_PROVIDER=gemini` is currently a stub in `runner/run-test.sh`.

## Scenario Error Handling (.ignore-errors)

The test runner defaults to fail-fast for scenario SQL. You can opt into error-tolerant
scenario execution for a specific skill by creating a `.ignore-errors` file in that
skill’s test directory (for example, `tests/altinity-expert-clickhouse-replication/.ignore-errors`).

Behavior:
- When `.ignore-errors` exists, `run-test.sh` executes scenario SQL via
  `run_script_in_db_ignore_errors`, which uses `clickhouse-client --ignore-error`.
- Without `.ignore-errors`, scenario SQL runs via `run_script_in_db`, and any
  ClickHouse error stops the test (due to `set -euo pipefail`).
- This only affects scenario SQL in `tests/<skill>/scenarios/*.sql`. It does not
  change schema creation, report generation, or verification.

Use `.ignore-errors` when:
- Errors are expected and are the signal under test (e.g., readonly replicas,
  Keeper issues, or intentionally failing queries).
- You want the test to continue so the skill can diagnose the failure state.

Do NOT use `.ignore-errors` when:
- Scenario SQL is meant to succeed (errors indicate a broken test setup).
- You need fail-fast to prevent misleading or incomplete reports.

Tradeoffs:
- Pros: simple opt-in per skill; preserves strict default; keeps tests running.
- Cons: coarse-grained; can mask unexpected failures within the scenario.

---

## SQL Version Matrix (deterministic, no LLM)

Runs every statement of every skill query pack (and runnable fenced SQL in
SKILL.md) against throwaway ClickHouse containers. Each container is a one-node
replicated cluster with embedded Keeper (`clickhouse-server/config.d/cluster-keeper.xml`)
and all optional system logs enabled, so `clusterAllReplicas('{cluster}', ...)`,
`system.zookeeper_connection`, `system.part_log`, `system.query_views_log` etc. are
exercised for real.

```bash
cd altinity-expert-clickhouse/tests
make matrix-up MATRIX_VERSIONS="24.8 25.8 26.8"    # ports 9248 / 9258 / 9268 on 127.0.0.1
make sql-matrix                                    # results/sql-matrix.{csv,md}; exit 1 on any failure
make matrix-down
```

Statement headers drive the matrix: `-- @check <id> <title>` names the check,
`-- @requires table:system.part_log | keeper | version>=26.8 | version<26.8 | kafka`
turns an expected absence into a SKIP instead of a FAIL, and `-- @skip-matrix <reason>`
excludes multi-step recipes. `make annotate-packs` adds headers to new statements.
Any error that is not covered by a requirement is a real defect.

## OpenCode Behaviour Evaluation (model under test)

`opencode/run_suite.sh` runs the model through OpenCode in a scratch project with a
read-only agent (`opencode/agent.md.tmpl`: bash allowlist for `clickhouse-client`,
`temperature: 0`), in one or more arms per skill:

- `none`: no skills available; the model uses its own knowledge.
- `old`: skills from a checkout of a previous version (`--old-skills DIR`).
- `new`: the working-tree skills.

`opencode/assert_run.py` scores each run from the `--format json` event stream:
skills loaded, files read, statements executed, whole-file execution
(`--queries-file`), write statements, report structure (header, findings table,
"Skipped and failed checks", "Next steps"), expected findings from
`tests/<skill>/expected.md`, and token/step/wall cost. `summarize.py` builds the
comparison table.

```bash
# fixtures first (any ClickHouse reachable with CLICKHOUSE_* env vars)
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_PORT=9258 USE_DOCKER=0 ./runner/run-test.sh --setup-only altinity-expert-clickhouse-merges
# then the model runs
make opencode-eval EVAL_MODEL=llmbox-01/qwen3.8-flash-next EVAL_PORT=9258 \
     EVAL_SKILLS="overview merges memory" EVAL_ARMS="none new" EVAL_LABEL=25.8
```

Skills must be project-local for OpenCode (`.opencode/skills`); the harness creates
that symlink itself. Use `--pure` (already set) so user plugins do not interfere.

## Coordinator Tests (Adaptive Chaining)
This suite does not currently automate multi-skill chaining. If you want to manually validate routing behavior, run `overview` first, then select a specialist skill based on the report’s recommendations:

```bash
cd altinity-expert-clickhouse/tests
make test-overview
make test-memory
make test-merges
```

---

## Validation Checklist

For each test:
- [ ] Agent selection matches symptom
- [ ] Runner can reach ClickHouse (or fails with clear stderr)
- [ ] SQL runs in order; later query errors don't erase earlier results (e.g. `query_views_log` issues)
- [ ] JSON output is valid and structurally correct (required keys; `.agent` matches the agent)
- [ ] Severity ratings are reasonable
- [ ] `chain_to` suggestions are relevant
- [ ] Recommendations are actionable
- [ ] No sensitive data leaked in output
