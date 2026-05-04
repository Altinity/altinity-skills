## Altinity Expert ClickHouse Skills Release: {{TAG}}

### Artifacts
- Individual skill zip files — one per diagnostic module (memory, merges, replication, storage, …):
  - https://github.com/Altinity/altinity-skills/releases/tag/{{TAG}}

### Install

**Claude Code / Codex (one-liner):**
```bash
npx skills add --agent claude-code Altinity/altinity-skills
npx skills add --agent codex      Altinity/altinity-skills
```

**Claude.ai (web):** download a zip above and upload via Settings → Capabilities → Add Skill.

### Container Image (GHCR)
- `docker pull ghcr.io/altinity/expert:latest`
- Package page: https://github.com/orgs/Altinity/packages/container/package/expert

### Helm Chart (OCI in GHCR)
- `helm install my-audit oci://ghcr.io/altinity/skills-helm-chart/altinity-expert`
- Package page: https://github.com/orgs/Altinity/packages/container/package/skills-helm-chart%2Faltinity-expert

### Documentation
- https://github.com/Altinity/altinity-skills/blob/main/README.md
- https://github.com/Altinity/altinity-skills/blob/main/altinity-expert-clickhouse/README.md
