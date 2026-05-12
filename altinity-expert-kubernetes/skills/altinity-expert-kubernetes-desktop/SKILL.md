---
name: altinity-expert-kubernetes-desktop
description: Provisions a local Kubernetes cluster on a Linux host for development and demo. Presents the user with kind, k3d, and minikube and their tradeoffs, then installs the chosen tool (with confirmation; falls back to printed commands if the user declines auto-install) and creates a single-node cluster (multi-node opt-in). Use whenever the user needs a local Kubernetes cluster for development or demo and does not already have one running — including as a precursor to skills that deploy software onto Kubernetes (e.g. altinity-deploy-clickhouse-kubernetes). Linux-only; for production use a managed Kubernetes service or kubeadm.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# Local Kubernetes (Dev Cluster)

Stand up a working single-node Kubernetes cluster on the user's Linux host so that downstream skills (or the user directly) have something to deploy into. The user picks the tool (kind, k3d, or minikube); this skill walks the install, cluster creation, and verification, then hands off.

This skill is tool-agnostic about *what* gets deployed onto the cluster afterwards. It exists so any skill or workflow that needs "a working local Kubernetes" can chain through it without re-implementing the install / create / verify dance.

---

## Action Mode

Hybrid:

- Read-only checks (`uname`, `docker info`, `kubectl version`, `kind/k3d/minikube version`, port and RAM probes) run automatically.
- Mutating steps (download and install kind/k3d/minikube/kubectl binaries, `kind/k3d/minikube create cluster`, `kubectl config use-context`, cluster deletion) require explicit user confirmation. Always print the exact command first.
- If the user declines auto-install of a tool, **print the manual install commands** and pause for the user to run them, then resume verification.

---

## Step 1 — Verify Inputs

Confirm with the user (or take from the calling skill):

- **Deployment intent** — must be **development / demo**. If the user signals production, stop and recommend a managed Kubernetes service or `kubeadm` instead; this skill is not for production.
- **Cluster name** — default `altinity-dev` so it doesn't collide with the user's other clusters.
- **Topology** — default **single-node** (control-plane only). If the user wants multi-node (testing anti-affinity, PDBs, replica scheduling), they need to say so.
- **Architecture** — `uname -m` resolves to `x86_64` (→ `amd64`) or `aarch64` (→ `arm64`); all three tools support both on Linux.

If anything's missing, ask. Do not proceed with placeholders.

---

## Step 2 — Verify Host

Run automatically:

```bash
uname -s -m
docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Docker not running"
free -h | awk '/^Mem:/ {print $2, $7}'    # total / available memory
df -h / | awk 'NR==2 {print $4, "free on /"}'
```

Stop and report if:

- OS is not Linux (this skill is Linux-only; on macOS / Windows the user should use Docker Desktop's Kubernetes or Rancher Desktop instead).
- Docker daemon is not running and the user has not installed an alternative container runtime that the chosen tool supports.
- Available memory is below ~2 GiB for single-node or ~4 GiB for multi-node — warn before proceeding.
- Less than ~5 GiB free on `/` — warn; container images and persistent volumes can fill disk quickly.

---

## Step 3 — Present the Tool Menu and Get the User's Pick

Show the user this comparison table before they choose. Do not pick silently — local-k8s preference is a real call.

| Tool        | Startup (single-node) | RAM idle | Multi-node           | Kubernetes flavor      | Best for                                              |
|-------------|------------------------|----------|----------------------|------------------------|-------------------------------------------------------|
| **kind**    | ~30 s                  | ~1.5 GiB | first-class (config) | vanilla upstream k8s   | Operator / controller development, CI parity with upstream k8s |
| **k3d**     | ~10 s                  | ~0.5 GiB | first-class (flags)  | k3s (slightly trimmed) | Lightest / fastest; good when RAM is tight            |
| **minikube**| ~60 s                  | ~2 GiB   | yes (flag)           | vanilla upstream k8s   | Familiar workflows; supports a VM driver if no Docker |

Recommendations to relay:

- **Pick kind** if the user is testing a Kubernetes operator or controller, or wants the closest parity with how operators are tested upstream.
- **Pick k3d** if memory is tight or fast iteration matters more than k8s parity. Watch for the small set of k3s differences (no in-tree cloud providers, simplified networking) — most application manifests are unaffected.
- **Pick minikube** if the user already knows it, or if they need the VM driver (e.g., running on a host where Docker isn't an option).

If the user has no preference, **recommend kind** as the default and say so — don't pick silently.

---

## Step 4 — Install the Chosen Tool and kubectl

For each binary (the chosen cluster tool + `kubectl`), do:

1. Check if it's already installed (`command -v <tool>`).
2. If missing, **propose the install command** and ask for confirmation.
3. If the user confirms, run the install command.
4. If the user declines, **print the commands** and pause so the user can run them manually; then re-verify before continuing.

### Install location

Prefer `~/.local/bin` (no `sudo`) if it's on PATH:

```bash
mkdir -p ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) INSTALL_DIR="$HOME/.local/bin" ;; *) INSTALL_DIR="/usr/local/bin" ;; esac
```

Use `sudo install` for `/usr/local/bin`, plain `install` for `~/.local/bin`. Show the user which directory will be used and confirm before any `sudo` step.

### Install commands

Architecture resolution (run once):

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
```

**kubectl** (needed regardless of cluster tool):

```bash
KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -fsSL -o kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
chmod +x kubectl
[ "$INSTALL_DIR" = "/usr/local/bin" ] && sudo install kubectl "$INSTALL_DIR/" || install kubectl "$INSTALL_DIR/"
rm kubectl
kubectl version --client
```

**kind**:

```bash
KIND_VER=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
curl -fsSL -o kind "https://kind.sigs.k8s.io/dl/${KIND_VER}/kind-linux-${ARCH}"
chmod +x kind
[ "$INSTALL_DIR" = "/usr/local/bin" ] && sudo install kind "$INSTALL_DIR/" || install kind "$INSTALL_DIR/"
rm kind
kind version
```

**k3d**:

```bash
# Official one-liner installer (downloads latest, into /usr/local/bin by default — uses sudo internally).
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version
```

**minikube**:

```bash
curl -fsSL -o minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
chmod +x minikube
[ "$INSTALL_DIR" = "/usr/local/bin" ] && sudo install minikube "$INSTALL_DIR/" || install minikube "$INSTALL_DIR/"
rm minikube
minikube version
```

After each install, run the `<tool> version` command and report the result.

---

## Step 5 — Create the Cluster

Use the user-confirmed cluster name (default `altinity-dev`).

### Single-node (default)

**kind:**

```bash
kind create cluster --name altinity-dev
```

**k3d:**

```bash
k3d cluster create altinity-dev
```

**minikube:**

```bash
minikube start --profile altinity-dev --driver=docker
```

### Multi-node (opt-in)

**kind** — uses the `assets/kind-multinode.yaml` shipped with this skill:

```bash
kind create cluster --name altinity-dev --config kind-multinode.yaml
```

**k3d:**

```bash
k3d cluster create altinity-dev --servers 1 --agents 2
```

**minikube:**

```bash
minikube start --profile altinity-dev --driver=docker --nodes=3
```

Cluster creation takes 30–90 seconds. Stream output so the user sees progress; don't suppress it.

---

## Step 6 — Verify the Cluster

Run automatically:

```bash
kubectl cluster-info
kubectl get nodes
kubectl get storageclass
kubectl get pods -A
```

Confirm:

- `kubectl cluster-info` reports a reachable control plane.
- `kubectl get nodes` shows the expected nodes in `Ready` status.
- A default `StorageClass` exists. The name depends on the tool:
  - **kind** → `standard` (rancher.io/local-path)
  - **k3d** → `local-path` (rancher.io/local-path)
  - **minikube** → `standard` (k8s.io/minikube-hostpath)
- System pods (`kube-system` namespace) are all `Running` / `Completed`.

Record the `StorageClass` name; downstream skills that deploy persistent workloads will need it.

If any verification fails, stop and report. Do not hand off a broken cluster.

---

## Step 7 — Handoff

The cluster is ready. Report a handoff summary back to whichever skill or workflow invoked this one:

```
cluster_tool:       kind | k3d | minikube
cluster_name:       altinity-dev
kubeconfig_context: <kubectl current-context output>
node_count:         1 | 3
storage_class:      standard | local-path
arch:               amd64 | arm64
notes:              <any warnings; e.g. memory near limit>
```

Then return to the calling skill, or — if no caller — tell the user the cluster is ready and offer common next steps (deploying a workload, installing an operator, etc.). A typical consumer is `altinity-deploy-clickhouse-kubernetes`, which expects `kubeconfig_context` and `storage_class` plugged into its inputs.

---

## Lifecycle and Cleanup

These commands stop, restart, and delete the cluster. Each is a mutating action — confirm before running.

| Action               | kind                                       | k3d                                       | minikube                                  |
|----------------------|--------------------------------------------|-------------------------------------------|-------------------------------------------|
| Stop (preserve data) | (kind has no stop; use `docker stop`)      | `k3d cluster stop altinity-dev`           | `minikube stop --profile altinity-dev`    |
| Start (resume)       | `docker start <kind-control-plane>`        | `k3d cluster start altinity-dev`          | `minikube start --profile altinity-dev`   |
| Delete               | `kind delete cluster --name altinity-dev`  | `k3d cluster delete altinity-dev`         | `minikube delete --profile altinity-dev`  |
| List clusters        | `kind get clusters`                        | `k3d cluster list`                        | `minikube profile list`                   |

Deleting the cluster also destroys all workloads and data in it. For a dev cluster that's usually the point; for anything you want to keep, back up via `kubectl exec` / volume snapshots / application-specific backup tooling before deletion.

---

## Why Not Production?

Each of these tools is explicitly a development tool:

- **kind** runs k8s nodes as Docker containers on a single host; no real HA, no node redundancy.
- **k3d** has the same single-host limitation, plus k3s removes some upstream features that production clusters rely on.
- **minikube** is single-host (multi-node is a single-host simulation).

For production Kubernetes, use a managed service (EKS, GKE, AKS, Altinity.Cloud) or `kubeadm` against real nodes, then run the relevant deploy skills against that cluster directly.

---

## Cross-Module Triggers

| Condition                                                                                | Next skill                                       |
|------------------------------------------------------------------------------------------|--------------------------------------------------|
| Cluster verified, caller is the ClickHouse deploy flow                                   | `altinity-deploy-clickhouse-kubernetes`          |
| Cluster verified, no specific caller                                                     | Report ready; ask the user what to deploy        |
| User asked for production K8s                                                            | Stop this skill; recommend managed K8s / kubeadm |
| Cluster creation failed (Docker not running, port in use, RAM exhausted)                 | Stop, report; do not hand off                    |
