---
name: altinity-deploy-clickhouse-kubernetes
description: Deploys ClickHouse on Kubernetes using the Altinity clickhouse-operator. Covers both Helm-based installation (recommended) and raw manifests, plus a ClickHouseInstallation (CHI) custom resource. Use for Kubernetes-based ClickHouse deployments — production or development.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# Deploy ClickHouse — Kubernetes (clickhouse-operator)

Install the Altinity clickhouse-operator into a Kubernetes cluster, then create a ClickHouseInstallation (CHI) custom resource that the operator reconciles into a working ClickHouse cluster.

Two install paths:

- **Helm** (recommended) — managed lifecycle, easy upgrades.
- **Raw manifests** — no Helm dependency; useful for inspectable, GitOps-style workflows.

Both paths converge on the same CHI workflow.

---

## Action Mode

Hybrid:

- Read-only checks (`kubectl version`, `kubectl get nodes`, `kubectl get crd`, `helm version`) run automatically.
- Mutating commands (`helm install`, `helm upgrade`, `kubectl apply`, `kubectl delete`) require explicit user confirmation. Print the exact command first.

---

## Step 1 — Verify Inputs

Confirm with the user (or take from `altinity-deploy-clickhouse-overview` / `-builds`):

- **Deployment intent** — production or development/demo?
- **Install path** — Helm or raw manifests?
- **Operator version** — pinned operator release.
- **Server image / Keeper image** — fully-qualified tags from `altinity-deploy-clickhouse-builds`.
- **Namespace** — for the operator (commonly `clickhouse-operator`) and for the ClickHouse cluster (separate namespace recommended).
- **Storage class** — for persistent volumes; must exist in the cluster.
- **Topology** — shards × replicas, Keeper count.
- **Default user password** — required for production.

If anything is missing, ask. Do not proceed with placeholders.

---

## Step 1.5 — Create Working Directory & README

Each install gets its own working directory under the user's CWD so manifests
and notes don't collide with other ClickHouse installs (Docker Compose, other
clusters, prior kind clusters, etc.).

Suggested layout (rename the top-level dir to something descriptive — e.g.
`clickhouse-k8s-dev/`, `clickhouse-k8s-<chi-name>/`):

```
<cwd>/<install-dir>/
├── kind/        # kind cluster config (kind installs only)
├── operator/    # operator install bundle, saved here (not /tmp)
├── chi/         # ClickHouseInstallation manifest
├── notes/       # scratch space for the user
└── README.md    # what this install is + how to start/stop/connect
```

Render `assets/README.md.template` into `<install-dir>/README.md`:

1. Substitute the placeholders (`${KIND_CLUSTER_NAME}`, `${OPERATOR_VERSION}`,
   `${CH_NAMESPACE}`, `${CHI_NAME}`, `${CH_CLUSTER_NAME}`, `${CH_SERVER_IMAGE}`,
   `${CH_TOPOLOGY}`, `${KEEPER_*}`, `${KUBE_CONTEXT}`, `${INSTALL_LABEL}`).
2. Strip blocks that don't apply, including the surrounding HTML markers:
   - Remove `<!-- KIND_BLOCK -->` … `<!-- /KIND_BLOCK -->` if not using kind.
   - Remove `<!-- REMOTE_BLOCK -->` … `<!-- /REMOTE_BLOCK -->` if using kind.
   - Remove `<!-- CH_BLOCK -->` … `<!-- /CH_BLOCK -->` if ClickHouse hasn't
     been applied yet (write the README early and re-render after Step 4).
   - Remove `<!-- KEEPER_BLOCK -->` … `<!-- /KEEPER_BLOCK -->` if no Keeper
     is deployed.

The README is intended to be re-rendered as the install progresses — it's fine
to write a partial version after Step 1.5 and update it after Steps 3 and 4 as
more components come online.

---

## Step 2 — Verify the Cluster

Run automatically:

```bash
kubectl version --output=yaml
kubectl get nodes
kubectl get storageclass
kubectl auth can-i create customresourcedefinitions
kubectl auth can-i create clusterroles
```

**If `kubectl` cannot reach a cluster** (the version command shows only the client, or `get nodes` errors with a connection refused / no current context):

- **Deployment intent = development/demo** → chain to `altinity-expert-kubernetes-desktop` to provision a local Kubernetes cluster (kind / k3d / minikube). When that skill returns with a working `kubeconfig_context` and `storage_class`, resume this skill from Step 2.
- **Deployment intent = production** → stop and recommend the user point `kubectl` at a managed Kubernetes service (EKS / GKE / AKS / Altinity.Cloud) or a `kubeadm`-installed cluster. Do not provision a local dev cluster for production.

Stop and report (without routing elsewhere) if:

- The user lacks cluster-admin (operator install needs CRDs and ClusterRoles).
- No `StorageClass` exists or the requested one is missing.
- Node count or capacity looks insufficient for the requested topology.

---

## Step 3 — Install the Operator

### Path A — Helm (recommended)

```bash
helm repo add altinity-clickhouse-operator \
  https://docs.altinity.com/clickhouse-operator/
helm repo update

# Pin the chart version to match the operator version chosen in Step 1.
helm install clickhouse-operator \
  altinity-clickhouse-operator/altinity-clickhouse-operator \
  --version <CHART_VERSION> \
  --namespace clickhouse-operator \
  --create-namespace \
  -f assets/helm-values.yaml
```

> **Verify the Helm repo URL and chart name at install time.** They have changed historically. Confirm against current Altinity documentation before running. If the URL above fails, ask the user for the canonical repo URL rather than guessing.

The `assets/helm-values.yaml` file in this skill ships sane defaults. Adjust before install for production (resource limits, image pull policy, RBAC scope).

### Path B — Raw manifests

The operator ships YAML manifests pinned to a specific release. Do not download from `master` for production.

```bash
# Replace <OPERATOR_VERSION> with the pinned version from Step 1.
OPERATOR_URL="https://github.com/Altinity/clickhouse-operator/raw/<OPERATOR_VERSION>/deploy/operator/clickhouse-operator-install-bundle.yaml"

curl -fsSL "$OPERATOR_URL" -o clickhouse-operator-install-bundle.yaml

# Inspect before applying.
less clickhouse-operator-install-bundle.yaml

kubectl apply -f clickhouse-operator-install-bundle.yaml
```

> **Verify the manifest URL before running.** The repo path and bundle filename can change between releases. Always pin to a specific tag and never use `master` for production.

### Verify operator readiness (both paths)

```bash
kubectl -n clickhouse-operator get pods
kubectl -n clickhouse-operator rollout status deployment/clickhouse-operator
kubectl get crd | grep clickhouse
```

Expect to see CRDs:
- `clickhouseinstallations.clickhouse.altinity.com`
- `clickhouseinstallationtemplates.clickhouse.altinity.com`
- `clickhouseoperatorconfigurations.clickhouse.altinity.com`
- `clickhousekeeperinstallations.clickhouse-keeper.altinity.com` (for Keeper-on-K8s)

---

## Step 4 — Create the ClickHouseInstallation (CHI)

The CHI is the user-facing resource. The operator reconciles it into StatefulSets, Services, ConfigMaps, and PVCs.

Use `assets/installation.yaml` as the starting template. It defines:

- 1 cluster, 1 shard, 1 replica (development default)
- Keeper reference (external Keeper service or in-CHI Keeper depending on topology)
- Persistent volume claim template using the chosen StorageClass
- Server image tag from the build skill
- Resource requests/limits commented for production tuning

Procedure:

1. Copy `assets/installation.yaml` to the working directory.
2. Substitute placeholders:
   - `${CH_NAMESPACE}` — target namespace for the cluster.
   - `${CH_SERVER_IMAGE}` — server image tag.
   - `${CH_STORAGE_CLASS}` — storage class for PVCs.
   - `${CH_STORAGE_SIZE}` — per-replica disk size (e.g. `100Gi`).
   - `${CH_DEFAULT_PASSWORD_SHA256}` — sha256 of the default user password (production only).
3. For multi-shard / multi-replica, set `clusters[0].layout.shardsCount` and `replicasCount`.
4. Show the user the rendered YAML before applying.

```bash
kubectl create namespace ${CH_NAMESPACE}   # if it does not already exist
kubectl apply -n ${CH_NAMESPACE} -f installation.yaml
```

---

## Step 5 — Production vs Development Defaults

| Setting              | Development                                | Production                                                          |
|----------------------|--------------------------------------------|---------------------------------------------------------------------|
| Operator version     | Latest stable                              | Pinned to a specific release                                        |
| Image tag            | Pinned acceptable                          | Pinned Altinity Stable Build                                        |
| Replicas per shard   | 1                                          | ≥2                                                                  |
| Keeper               | Single Keeper acceptable                   | 3-node Keeper (separate StatefulSet or via clickhouse-keeper-operator) |
| Storage              | Default StorageClass OK                    | Explicit StorageClass with backup policy                            |
| Resource requests    | Unset acceptable                           | Set CPU and memory requests; set memory limits                      |
| `imagePullPolicy`    | `IfNotPresent`                             | `IfNotPresent` with pinned tag (never `latest`)                     |
| Default user         | Empty password OK                          | sha256 password or certificate auth                                 |
| Service exposure     | `ClusterIP`                                | `ClusterIP` + Ingress / LoadBalancer with TLS (TLS out of MVP scope) |
| PodDisruptionBudget  | Skip                                       | Set                                                                 |
| Anti-affinity        | Skip                                       | Required across replicas in the same shard                          |

---

## Step 6 — Wait for Reconciliation

```bash
# Watch the CHI status.
kubectl -n ${CH_NAMESPACE} get chi -w

# Inspect operator events.
kubectl -n ${CH_NAMESPACE} describe chi <chi-name>

# Pods.
kubectl -n ${CH_NAMESPACE} get pods -l clickhouse.altinity.com/chi=<chi-name>
```

Expect the CHI status to transition to `Completed`. Each ClickHouse pod should be `Ready`.

---

## Step 7 — Validate

Hand off to `altinity-deploy-clickhouse-smoke-test` against the new endpoint.

```bash
# Find the service.
kubectl -n ${CH_NAMESPACE} get svc -l clickhouse.altinity.com/chi=<chi-name>
```

Use the cluster service (e.g. `clickhouse-<chi-name>`) on port 8123 (HTTP) or 9000 (native) from inside the cluster. For ad-hoc local access:

```bash
kubectl -n ${CH_NAMESPACE} port-forward svc/clickhouse-<chi-name> 8123:8123 9000:9000
```

Do not declare success until smoke tests pass.

---

## Cross-Module Triggers

| Condition                                | Next skill                              |
|------------------------------------------|-----------------------------------------|
| CHI reaches `Completed`                  | `altinity-deploy-clickhouse-smoke-test` |
| Production intent                        | Flag TLS, RBAC, backup, monitoring as follow-ups |
| User asks about scaling / topology change | Update CHI spec; operator reconciles    |
