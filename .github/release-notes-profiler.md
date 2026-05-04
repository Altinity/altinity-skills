## Altinity Profiler ClickHouse Skill Release: {{TAG}}

### Artifacts
- `altinity-profiler-clickhouse.zip` — the profiler skill bundle (SKILL.md + archetypes + pipeline + templates + edge-cases + tools):
  - https://github.com/Altinity/altinity-skills/releases/tag/{{TAG}}

### What it does
Profiles a live ClickHouse cluster via MCP and generates a per-cluster analyst Skill — a 6-file knowledge base (schema map, query patterns, engine idioms, pipeline graph, glossary, README) the user saves in claude.ai or installs locally.

### Install

**Claude Code / Codex (one-liner):**
```bash
npx skills add --agent claude-code Altinity/altinity-skills/altinity-profiler-clickhouse
npx skills add --agent codex      Altinity/altinity-skills/altinity-profiler-clickhouse
```

**Claude.ai (web):** download `altinity-profiler-clickhouse.zip` above and upload via Settings → Capabilities → Add Skill.

### Usage
```
/altinity-profiler-clickhouse Profile this cluster and generate an analyst skill
$altinity-profiler-clickhouse Profile this cluster and generate an analyst skill
```

### Documentation
- https://github.com/Altinity/altinity-skills/blob/main/README.md
- https://github.com/Altinity/altinity-skills/blob/main/altinity-profiler-clickhouse/SKILL.md
