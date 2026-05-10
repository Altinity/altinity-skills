# Skills

This repository contains skills used for ClickHouse DB performance and schema analysis and helper workflows.

## Core Skills
- `altinity-expert-clickhouse/`: Modular ClickHouse diagnostic skill set. Each module is a standalone skill under `altinity-expert-clickhouse/skills/` (e.g., memory, merges, replication).
- `altinity-profiler-clickhouse/`: Profiles a live ClickHouse cluster via MCP and generates a per-cluster analyst Skill (schema map, query patterns, engine idioms) that can be saved in claude.ai.

## Packaging and Releases

Each skill group has its own release workflow and tag scheme:

| Skill group | Tag pattern | Workflow |
|---|---|---|
| `altinity-expert-clickhouse` | `expert-v*` | `.github/workflows/expert-skills.yaml` |
| `altinity-profiler-clickhouse` | `profiler-v*` | `.github/workflows/profiler-skill.yaml` |

On every PR / push to `main`, changed skills are packaged and uploaded as workflow artifacts. On a matching tag push, all skills in that group are packaged and published as GitHub Release assets.

## Installing Skills

### Claude Code (CLI)

**One-liner (recommended):**
```bash
npx skills add --agent claude-code Altinity/altinity-skills/altinity-expert-clickhouse/
npx skills add --agent claude-code Altinity/altinity-skills/altinity-profiler-clickhouse/
```

This installs all skills into `~/.claude/skills/`.

**Install a single skill:**
```bash
npx skills add --agent claude-code Altinity/altinity-skills/altinity-expert-clickhouse/skills/altinity-expert-clickhouse-overview
```

**Manual install:**
```bash
git clone https://github.com/Altinity/altinity-skills.git
# Copy a specific skill
cp -r altinity-skills/altinity-expert-clickhouse/skills/altinity-expert-clickhouse-overview ~/.claude/skills/
# Or symlink the whole skills directory
ln -s "$(pwd)/altinity-skills/altinity-expert-clickhouse/skills" ~/.claude/skills/altinity-expert-clickhouse
```

**Usage** — invoke a skill with a slash command:
```
/altinity-expert-clickhouse-overview Analyze cluster health
/altinity-profiler-clickhouse Profile this cluster and generate an analyst skill
```

---

### Claude.ai (web)

1. Download skill zip files from the [latest GitHub Release](https://github.com/Altinity/altinity-skills/releases/latest).
2. In Claude.ai, go to **Settings → Capabilities** (or **Admin Settings → Capabilities** for org-wide deployment).
3. Click **Add Skill** and upload the zip file.

Each skill is a separate zip. Upload as many as needed.

---

### Codex CLI

**One-liner (recommended):**
```bash
npx skills add --agent codex Altinity/altinity-skills/altinity-expert-clickhouse/
npx skills add --agent codex Altinity/altinity-skills/altinity-profiler-clickhouse/
```

This installs all skills into `~/.codex/skills/`.

**Manual install:**
```bash
git clone https://github.com/Altinity/altinity-skills.git
# Copy a specific skill
cp -r altinity-skills/altinity-expert-clickhouse/skills/altinity-expert-clickhouse-overview ~/.codex/skills/
# Or symlink the whole skills directory
ln -s "$(pwd)/altinity-skills/altinity-expert-clickhouse/skills" ~/.codex/skills/altinity-expert-clickhouse
```

**Usage** — invoke a skill with a dollar-sign prefix:
```
$altinity-expert-clickhouse-overview Analyze cluster health
$altinity-profiler-clickhouse Profile this cluster and generate an analyst skill
```

---

### Gemini CLI

```bash
npx skills add --agent gemini Altinity/altinity-skills/altinity-expert-clickhouse/
npx skills add --agent gemini Altinity/altinity-skills/altinity-profiler-clickhouse/
```

Or manually:
```bash
git clone https://github.com/Altinity/altinity-skills.git
mkdir -p ~/.gemini/skills
ln -s "$(pwd)/altinity-skills/altinity-expert-clickhouse/skills" ~/.gemini/skills/altinity-expert-clickhouse
```

**Usage:**
```
use skill `altinity-expert-clickhouse-overview` Analyze cluster health
```


## Docker Image

A pre-built Docker image with Claude Code, Codex CLI, and all skills is available:

```bash
docker pull ghcr.io/altinity/expert:latest
```

The image includes:
- `claude` - Anthropic Claude Code CLI
- `codex` - OpenAI Codex CLI
- `altinity-mcp` - Altinity MCP server

### Run locally with Docker

```bash
# Claude agent
docker run -it --rm \
  -v ~/.claude:/home/bun/.claude \
  ghcr.io/altinity/expert:latest \
  claude --dangerously-skip-permissions -p "/altinity-expert-clickhouse-overview Analyze cluster health"

# Codex agent
docker run -it --rm \
  -v ~/.codex:/home/bun/.codex \
  ghcr.io/altinity/expert:latest \
  codex exec --dangerously-bypass-approvals-and-sandbox "\$altinity-expert-clickhouse-overview Analyze cluster health"
```

## Kubernetes Helm Chart

A Helm chart is provided to run skills as Kubernetes Jobs in non-interactive mode.

Chart details:
- chart name: `altinity-expert`
- source path: `helm/skills-agent`
- detailed chart docs: `helm/skills-agent/README.md`

### Install the chart

From OCI registry (recommended):

```bash
# Use --version to pin a chart release in production.
helm install my-audit oci://ghcr.io/altinity/skills-helm-chart/altinity-expert \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Analyze ClickHouse cluster health" \
  --set-file credentials.claudeCredentials=~/.claude/.credentials.json
```

From local repository:

```bash
git clone https://github.com/Altinity/skills.git
cd skills

helm install my-audit ./helm/skills-agent \
  --set agent=codex \
  --set model=gpt-5.3-codex \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Analyze ClickHouse cluster health and summarize top risks" \
  --set-file credentials.codexAuth=~/.codex/auth.json
```

### Quick validation

```bash
helm lint ./helm/skills-agent

# Render defaults
helm template my-audit ./helm/skills-agent

# Render an IRSA-enabled variant
helm template my-audit ./helm/skills-agent \
  --set storeResults.enabled=true \
  --set storeResults.s3Bucket=my-results-bucket \
  --set storeResults.iamRoleArn=arn:aws:iam::123456789012:role/my-eks-s3-role \
  --set serviceAccount.create=true
```

### Key configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `debugMode` | Create debug Pod (`sleep infinity`) instead of Job | `false` |
| `agent` | Agent CLI: `claude` or `codex` | `claude` |
| `model` | Codex model (`agent=codex` only) | `""` |
| `skillName` | Skill name without leading `/` or `$` | `altinity-clickhouse-expert` |
| `prompt` | Prompt passed to skill | `Analyze ClickHouse cluster health` |
| `image.repository` | Docker image repository | `ghcr.io/altinity/expert` |
| `image.tag` | Docker image tag | `latest` |
| `imagePullSecrets` | Pull secrets for private registries | `[]` |
| `job.restartPolicy` | Pod restart policy | `Never` |
| `job.backoffLimit` | Job retries | `0` |
| `job.ttlSecondsAfterFinished` | Cleanup TTL | `3600` |
| `job.activeDeadlineSeconds` | Job timeout | `1800` |
| `resources` | CPU/memory requests and limits | see `values.yaml` |
| `extraEnv` | Additional env vars for container | `[]` |
| `clickhouse.host` | ClickHouse host | `localhost` |
| `clickhouse.port` | ClickHouse port | `9440` |
| `clickhouse.user` | ClickHouse user | `default` |
| `clickhouse.password` | ClickHouse password | `""` |
| `clickhouse.tls.enabled` | Enable TLS in generated configs | `true` |
| `clickhouse.tls.ca` | PEM CA cert content | `""` |
| `clickhouse.tls.cert` | PEM client cert content | `""` |
| `clickhouse.tls.key` | PEM client key content | `""` |
| `credentials.create` | Create credentials/config secret from values | `true` |
| `credentials.existingSecretName` | Existing secret to mount when `create=false` | `""` |
| `serviceAccount.create` | Create ServiceAccount | `false` |
| `serviceAccount.name` | ServiceAccount name override | `""` |
| `serviceAccount.namespace` | Namespace for created ServiceAccount | `""` |
| `serviceAccount.annotations` | Extra ServiceAccount annotations | `{}` |
| `storeResults.enabled` | Upload successful run logs to S3 | `false` |
| `storeResults.s3Bucket` | S3 bucket name | `""` |
| `storeResults.s3Prefix` | S3 key prefix | `agent-results` |
| `storeResults.iamRoleArn` | IRSA role ARN (EKS) | `""` |
| `storeResults.awsAccessKeyId` | AWS key id when not using IRSA | `""` |
| `storeResults.awsSecretAccessKey` | AWS secret when not using IRSA | `""` |
| `storeResults.awsRegion` | AWS region | `us-east-1` |

### Debug mode

```bash
helm install my-debug oci://ghcr.io/altinity/skills-helm-chart/altinity-expert \
  --set debugMode=true \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Analyze ClickHouse cluster health" \
  --set-file credentials.claudeCredentials=~/.claude/.credentials.json
```

```bash
kubectl exec -it <release-name>-altinity-expert-debug -- /bin/sh
kubectl logs <release-name>-altinity-expert-debug
```

### Store results in S3

IRSA mode (recommended on EKS):

```bash
helm install my-audit oci://ghcr.io/altinity/skills-helm-chart/altinity-expert \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Analyze ClickHouse cluster health" \
  --set-file credentials.claudeCredentials=~/.claude/.credentials.json \
  --set storeResults.enabled=true \
  --set storeResults.s3Bucket=my-results-bucket \
  --set storeResults.s3Prefix=agent-results \
  --set storeResults.iamRoleArn=arn:aws:iam::123456789012:role/my-eks-s3-role \
  --set serviceAccount.create=true
```

Static AWS credentials mode:

```bash
helm install my-audit oci://ghcr.io/altinity/skills-helm-chart/altinity-expert \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Analyze ClickHouse cluster health" \
  --set-file credentials.claudeCredentials=~/.claude/.credentials.json \
  --set storeResults.enabled=true \
  --set storeResults.s3Bucket=my-results-bucket \
  --set storeResults.awsAccessKeyId=AKIAIOSFODNN7EXAMPLE \
  --set storeResults.awsSecretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

When `storeResults.enabled=true`:
1. Logs are written in-container to `/workspace/${TIMESTAMP}/agent-execution.log`.
2. On exit code `0`, the full work directory uploads to `s3://${S3_BUCKET}/${S3_PREFIX}/${TIMESTAMP}/`.
3. On non-zero exit code, upload is skipped.

### Using existing secrets

When `credentials.create=false`, the existing secret must contain:
- `codex-auth.json`
- `claude-credentials.json`
- `clickhouse-client-config.xml`
- `altinity-mcp-config.yaml`
- optional TLS keys if enabled: `clickhouse-ca.crt`, `clickhouse-client.crt`, `clickhouse-client.key`

```bash
# Example: install using an existing secret
helm install my-audit ./helm/skills-agent \
  --set credentials.create=false \
  --set credentials.existingSecretName=agent-credentials \
  --set skillName=altinity-expert-clickhouse-overview \
  --set prompt="Run diagnostics"
```

### Monitor execution

```bash
kubectl get jobs -l app.kubernetes.io/instance=my-audit
kubectl logs -l app.kubernetes.io/instance=my-audit -f
kubectl get pods -l app.kubernetes.io/instance=my-audit
```

## Kubernetes Bash Launcher

Helm-free alternative is available for interactive expert runs with `cloudctl` + `kubectl`.

- Script: `k8s/scripts/run-expert-job.sh`
- Template: `k8s/templates/expert-job.yaml`
- Docs: `k8s/README.md`

Example:

```bash
export EXPERT_CH_USER=default
export EXPERT_RUNTIME=codex
k8s/scripts/run-expert-job.sh demo prod 'my-clickhouse-password'
```

## Experimental Skills
- `experimental/codex-summarize-pipeline/`: Chunk→reduce pipeline for summarizing large articles/files into `summaries/*.md`.
- `experimental/github-triage/`: Search and summarize relevant GitHub issues/PRs using `gh`.
- `experimental/sub-agent/`: Prototype sub-agent workflow (multi-agent attempt by exec of next codex/claude inside skill processing).

## Conventions
- Each skill lives in its own directory and includes a `SKILL.md`.
- Supporting content is stored next to `SKILL.md` (e.g., `modules/`, scripts, prompts).
