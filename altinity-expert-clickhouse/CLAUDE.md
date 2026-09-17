# Altinity Expert ClickHouse Skills

ClickHouse diagnostic skills for Claude Code and other LLM providers.

## Project Structure

```
altinity-expert-clickhouse/
├── skills/                     # Skill definitions (SKILL.md files)
│   └── altinity-expert-clickhouse-*/
│       ├── SKILL.md           # Procedure, interpretation rules, report format, routing
│       ├── checks.sql (+ other packs)  # Statements with -- @check / -- @requires headers
│       └── reference.md       # Optional background, read on demand
├── tests/                      # Test suite
│   ├── Makefile               # Test targets
│   ├── sql-matrix/            # Statement-level SQL matrix across ClickHouse versions
│   ├── opencode/              # OpenCode + model behaviour evaluation harness
│   ├── runner/                # Test orchestration
│   │   ├── run-test.sh        # Main test runner
│   │   ├── verify-report.sh   # LLM-based report verification
│   │   └── lib/common.sh      # Shared helpers (run_query, etc.)
│   └── altinity-expert-clickhouse-*/  # Per-skill test cases
│       ├── dbschema.sql       # Test database schema
│       ├── prompt.md          # Test prompt for LLM
│       ├── expected.md        # Expected findings for verification
│       ├── scenarios/         # SQL scripts to populate test data
│       └── reports/           # Generated reports (gitignored)
└── README.md                  # User documentation
```

## Running Tests

Tests require a ClickHouse connection and an LLM provider (codex, claude, or gemini).

```bash
cd tests

# Set ClickHouse connection
export CLICKHOUSE_HOST=localhost
export CLICKHOUSE_PORT=9000
export CLICKHOUSE_USER=default
export CLICKHOUSE_PASSWORD=       # if needed
export CLICKHOUSE_SECURE=0        # 1 for TLS

# Run a single skill test
make test-memory                  # default provider (codex)
make test-memory-claude           # Claude provider
make test-memory-codex            # Codex provider

# Run all tests
make test-all
make test-all-claude
```

## LLM Providers

The test runner (`tests/runner/run-test.sh`) supports multiple LLM providers:

| Provider | CLI Tool | Environment Variables |
|----------|----------|----------------------|
| `codex`  | `codex`  | `CODEX_MODEL`, `CODEX_VERIFY_MODEL` |
| `claude` | `claude` | `CLAUDE_MODEL` |
| `gemini` | stub     | not yet implemented |

Set `LLM_PROVIDER` to select the provider:
```bash
LLM_PROVIDER=claude make test-memory
```

## Test Flow

1. **Setup**: Create test database, apply schema, run scenarios
2. **Analyze**: Send prompt to LLM with skill instructions
3. **Verify**: Compare report against expected.md using LLM
4. **Cleanup**: Optional database cleanup

## Key Files for Development

- `tests/runner/lib/common.sh` - ClickHouse client helpers
  - `run_query "SQL"` - Run single query
  - `run_script_in_db file.sql dbname` - Run SQL script
  - `validate_connection` - Test ClickHouse connectivity

- `tests/runner/run-test.sh` - Main orchestrator
  - Parses arguments, sets up database
  - Invokes LLM provider
  - Calls verify-report.sh

## Adding a New Skill

1. Create `skills/altinity-expert-clickhouse-NAME/SKILL.md`
2. Create test directory `tests/altinity-expert-clickhouse-NAME/`
3. Add `dbschema.sql`, `prompt.md`, `expected.md`
4. Add scenarios in `scenarios/` directory
5. Add Makefile target in `tests/Makefile`

## SQL matrix and OpenCode evaluation

```bash
cd tests
make matrix-up                 # ClickHouse 24.8/25.8/26.8 containers (one-node cluster + Keeper)
make sql-matrix                # every pack statement on every version; fails on undeclared errors
make annotate-packs            # add @check/@requires headers to new statements
make opencode-eval EVAL_MODEL=llmbox-01/qwen3.8-flash-next EVAL_PORT=9258 EVAL_SKILLS="overview merges" EVAL_ARMS="none new"
make matrix-down
```

Skill authoring rules live in `SKILL_TEMPLATE.md`; conventions in `ARCHITECTURE.md`.

## Guidelines

- Use `tests/runner/lib/common.sh` helpers for ClickHouse queries
- Do not use MCP tools or curl for ClickHouse access
- Reports should use severity ratings: Critical, Major, Moderate, Minor, OK
- Expected.md should list key findings to verify (not full report text)