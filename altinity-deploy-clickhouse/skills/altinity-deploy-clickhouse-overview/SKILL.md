---
name: altinity-deploy-clickhouse-overview
description: Plans and dispatches a ClickHouse deployment. Use when the user asks to install, set up, deploy, stand up, or provision ClickHouse — in Docker, Kubernetes, on bare metal, or on Altinity.Cloud — and routes to the right specialist deploy skill.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# Deploy ClickHouse — Overview

Entry point for ClickHouse deployments. Determine target environment, build channel, and topology, then route to the specialist skill. Do not start installing anything from this skill.

---

## Action Mode

These deploy skills follow a **hybrid action mode**:

- Read-only checks (e.g. `docker ps`, `kubectl get nodes`, repo reachability) run automatically.
- Mutating commands (`docker compose up`, `helm install`, `kubectl apply`, package installs) require explicit user confirmation before execution.
- Always print the exact command and expected effect before asking for confirmation.

---

## Step 1 — Gather Requirements

Ask the user (one prompt, all questions):

1. **Target environment** — Docker (Compose), Kubernetes, bare metal, or Altinity.Cloud?
2. **Deployment intent** — **production** or **development/demo**? This is load-bearing: it changes defaults for persistence, replication, resource limits, security, and image pinning. See *Production vs Development* below.
3. **Topology** — single-node (dev/demo), or clustered (shards × replicas + Keeper)?
4. **Build flavor** — which of the four supported ClickHouse builds:
   - **Altinity Stable Builds** — Altinity's long-term-support, security-backported track. **Default when the user has no preference.** Production deployments and any workload that doesn't specifically need Antalya-only features.
   - **Altinity Antalya Builds** — feature-forward Altinity track. Pick for new application development that needs Iceberg-backed data lakes, Hybrid Tables, swarm clusters, OAuth/OIDC, fast Parquet reads, or other cutting-edge capabilities. Altinity's own docs note Antalya is *not* for production use; choose deliberately.
   - **Altinity FIPS Builds** — FIPS 140-3 compatible cryptography. Pick when the user has an explicit FIPS compliance requirement.
   - **ClickHouse Official Builds** — upstream from ClickHouse, Inc. Pick when the user explicitly wants to track upstream.

   If the user has no preference, default to **Altinity Stable** and tell them so — don't silently pick. If the user describes a workload that needs Antalya-track features, surface Antalya as the right fit and explain the feature-forward support tradeoff so they can choose deliberately. Offer `altinity-deploy-clickhouse-builds` for a full comparison.
5. **Distribution form** — container image, Linux package (DEB / RPM), or binary tarball? Determined by the target environment in most cases (Docker/K8s ⇒ container), but call it out for bare-metal.
6. **Machine architecture** — x86_64 (Intel / AMD) or aarch64 (ARM, including Apple Silicon, AWS Graviton, Ampere)? Not every build flavor publishes artifacts for every architecture — `altinity-deploy-clickhouse-builds` resolves this.
7. **Version** — specific version, latest LTS, or "let me recommend"?
8. **Scale hint** — expected data volume, ingest rate, query concurrency (rough is fine; informs sizing).

If the user has not stated a target, deployment intent, or build flavor, do not guess. Ask.

---

## Production vs Development

The intent answer in Step 1 propagates to every downstream installer skill. Apply these defaults unless the user overrides:

| Concern              | Development / Demo                          | Production                                                  |
|----------------------|---------------------------------------------|-------------------------------------------------------------|
| Image / package tag  | Latest stable acceptable                    | Pinned to specific Altinity Stable Build version            |
| Persistence          | Named volumes OK; ephemeral acceptable      | Named volumes / PVCs with backups; never `tmpfs`            |
| Replication / Keeper | Single Keeper, single replica acceptable    | At least 3 Keepers, ≥2 replicas per shard                   |
| Resource limits      | Unset or generous defaults                  | Explicit CPU / memory requests + limits                     |
| Default user / auth  | `default` with no password OK locally       | Strong password or certificate auth; rotate `default` user  |
| Network exposure     | localhost only / dev network                | Restricted to required CIDRs; TLS for client and inter-node |
| Logs / monitoring    | Defaults                                    | Hooked to centralized logging + metrics                     |
| Smoke test depth     | Basic connectivity + version                | Full smoke test including replication and writeability      |

When the user says "production," do not silently apply dev defaults to save steps. If a production-grade default cannot yet be configured (e.g. TLS is out of scope for the MVP), call it out explicitly as a follow-up.

---

## Step 2 — Select the Build

Always route through `altinity-deploy-clickhouse-builds` to lock in:

- **Build flavor** — Official, Antalya, Altinity Stable, or Altinity FIPS.
- **Version / channel** — pinned version, LTS line, or latest stable.
- **Distribution form** — container image, DEB / RPM package, or binary tarball.
- **Architecture** — x86_64 or aarch64. Not every flavor × form × architecture combination exists.
- **Concrete coordinates** — image tag, repo URL, or tarball URL.

The build skill educates the user about the differences between flavors when they're unsure, then returns a concrete reference (e.g. `altinity/clickhouse-server:<version-with-flavor-suffix>`) that downstream installer skills consume. **Altinity Stable** is the default flavor when the user states no preference; pick Antalya only when the workload genuinely needs feature-forward capabilities, FIPS only when there is an explicit compliance requirement, and ClickHouse Official only when the user explicitly wants to track upstream.

---

## Step 3 — Route to the Installer

| Target                             | Skill                                      |
|------------------------------------|--------------------------------------------|
| Docker / Docker Compose            | `altinity-deploy-clickhouse-docker`        |
| Kubernetes (clickhouse-operator)   | `altinity-deploy-clickhouse-kubernetes`    |
| Bare metal (apt/yum/tar + systemd) | *(planned: `altinity-deploy-clickhouse-bare-metal`)* |
| Altinity.Cloud                     | *(planned: `altinity-deploy-clickhouse-altinity-cloud`)* |

**Kubernetes + development/demo intent + no existing cluster:** chain through `altinity-expert-kubernetes-desktop` first to provision a local Kubernetes cluster (kind / k3d / minikube on Linux), then proceed to `altinity-deploy-clickhouse-kubernetes` against that cluster. If the user already has a cluster (managed service, kubeadm, existing local cluster), skip the desktop-cluster step and go directly to `altinity-deploy-clickhouse-kubernetes`.

If the user picks a planned-but-unbuilt target, say so and offer the closest available alternative.

---

## Step 4 — Validate the Install

After any installer skill completes, run `altinity-deploy-clickhouse-smoke-test` against the new deployment. Do not declare the deployment successful without it.

---

## Report

When the deployment is done, summarize:

- Target environment and topology
- Build channel and version installed
- Connection coordinates (host, port, user)
- Smoke-test result
- Next steps the user should consider (backup setup, RBAC, monitoring, TLS) — these are out of scope for the MVP skills but worth flagging.
