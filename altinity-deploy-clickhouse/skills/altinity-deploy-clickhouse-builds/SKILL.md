---
name: altinity-deploy-clickhouse-builds
description: Finds the right ClickHouse build and educates users on the tradeoffs between the four supported flavors (ClickHouse Official, Altinity Antalya, Altinity Stable, Altinity FIPS), the three distribution forms (container, package, binary tarball), and the supported machine architectures (x86_64, aarch64). Use when picking a build, comparing build flavors, configuring apt/yum repos, choosing a Docker image tag, or downloading a tarball for ClickHouse.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# ClickHouse Build Selection

Pick the right ClickHouse build along three independent axes — **flavor**, **distribution form**, and **architecture** — and produce concrete coordinates (image tag, repo URL, or tarball URL) that downstream installer skills consume. Educate the user on tradeoffs when they're unsure. Do not install anything from this skill.

---

## Action Mode

Hybrid:

- Read-only checks (registry / repo reachability, image tag existence, latest-version queries) run automatically.
- No mutating steps in this skill — selection only. Installer skills are responsible for fetching and installing.

---

## Documentation References

When the user asks a question that requires authoritative documentation (build flavor scope, FIPS support model, supported OS matrix, current install command for a specific distro), consult `references/INDEX.md`. It groups canonical URLs by topic — build flavors, artifact locations, architecture/OS, compliance — and tells you when each source is the right one to fetch.

Use `WebFetch` to read the URL when current data matters; do not paraphrase from memory if a definitive answer is available at a known canonical source.

---

## Step 1 — Choose Build Flavor

There are four supported ClickHouse builds. Each has a distinct purpose; the choice is rarely about "newer = better."

### 1. ClickHouse Official Builds

- **Source:** ClickHouse, Inc. (the upstream project).
- **Audience:** Users who want to track upstream directly, run the latest features as soon as they ship, or match what the upstream community is testing. Long Term Support builds appear in March and August (by convention, check docs). All other builds are monthly with short community support tails. 
- **Cadence:** Frequent releases on the upstream cadence; LTS tags exist but support windows differ from Altinity's.
- **Support:** Community / commercial support from ClickHouse, Inc.
- **Recommended for:** Development, evaluation of new features, environments aligned with the upstream community.

### 2. Altinity Antalya Builds

- **Source:** Altinity.
- **Audience:** Teams **developing new applications** that need cutting-edge capabilities — Iceberg-backed data lakes, Hybrid Tables (MergeTree + Iceberg in one query), swarm clusters, fast Parquet reads, OAuth/OIDC, tiered storage from MergeTree to shared Iceberg. Antalya builds are 100% compatible with matching upstream ClickHouse versions, so applications built on Antalya remain portable.
- **Cadence:** Faster than Altinity Stable; carries Altinity's feature-forward changes.
- **Support:** Altinity, on a feature-forward track rather than a long-support track.
- **Recommended for:** New application development that genuinely needs Antalya-only features. If your workload runs fine on stock ClickHouse, prefer Altinity Stable.

> ⚠️ **Use only if you need the features.** Altinity's own documentation states Project Antalya is *not* for production use ([docs.altinity.com/altinityantalya](https://docs.altinity.com/altinityantalya/)) — read this as "don't pick Antalya by default; pick it because you specifically need the cutting-edge capabilities and accept a feature-forward support track." For workloads that don't depend on those capabilities, **Altinity Stable** is the production choice.
>
> **Verify additional scope.** Antalya features are improving rapidly; specifics (which features ride on it, which versions are current, exact distribution coverage) change over time. Confirm the current scope against Altinity's documentation before recommending.

### 3. Altinity Stable Builds

- **Source:** Altinity.
- **Audience:** Users who explicitly want the **conservative track** — long-term support, slower cadence, qualified releases only. Based on upstream Long Term Support (LTS) releases with selected backports and bugfixes needed by Altinity users. 
- **Cadence:** Slower than upstream; selected upstream releases promoted to Altinity Stable lines after qualification.
- **Support:** Altinity, with long-term support windows and security backports — security fixes land on supported lines without forcing a major-version jump.
- **Recommended for:** Production deployments and any case where the workload doesn't need Antalya-only features. **This is the default when no preference is stated.**

### 4. Altinity FIPS Builds

- **Source:** Altinity.
- **Audience:** Users in **regulated environments** that require FIPS 140-3 compatible cryptography (US federal, healthcare, finance, defense, certain enterprise compliance regimes).
- **Cadence:** Tracks Altinity Stable; the differentiator is the cryptographic module, not the feature set.
- **Support:** Altinity, with the validated crypto module and the Stable-track support model.
- **Recommended for:** Deployments with an explicit FIPS 140-3 requirement. Do not choose this flavor casually — it constrains distribution coverage (see matrix below) and adds compliance obligations.

### Default recommendations

| User profile / signal                                                                                  | Recommended flavor                                  |
|--------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| **No preference stated**                                                                               | **Altinity Stable** (default)                       |
| Building a new application that needs Iceberg / Hybrid Tables / swarm / OAuth / cutting-edge features  | Altinity Antalya (accept feature-forward track)     |
| Explicit FIPS 140-3 / regulated-compliance requirement                                                 | Altinity FIPS                                       |
| Explicit ask to track upstream / "vanilla ClickHouse"                                                  | ClickHouse Official                                 |
| Development / demo with no preference                                                                  | Altinity Stable (Antalya if exploring its features) |

When no preference is stated, default to **Altinity Stable** and tell the user why. If the user describes a workload that needs Iceberg, Hybrid Tables, swarm clusters, or other Antalya-track features, surface Antalya as the right fit and explain the feature-forward support tradeoff so they can choose deliberately.

---

## Step 2 — Choose Distribution Form

Three forms. The target environment usually decides this, but call it out so the user can override.

### Container image (OCI)

- **Use for:** Docker, Docker Compose, Kubernetes, Podman.
- **Pros:** Self-contained, reproducible, easy to roll back by changing a tag.
- **Cons:** No host-level customization without rebuild.
- **Pinning rule:** Always use a fully-qualified version tag in production. Never `latest`, `stable`, or major-only (`24`).

### Linux package (DEB / RPM)

- **Use for:** Bare-metal Linux installs managed by `apt` (Debian, Ubuntu) or `yum` / `dnf` (RHEL, Rocky, Alma, CentOS Stream, Fedora).
- **Pros:** Integrates with systemd, package-manager-native upgrades, signed packages.
- **Cons:** Distribution-specific; must match the host's package manager and base OS major version.
- **Pinning rule:** Pin the package version explicitly (`apt install clickhouse-server=<version>` / `dnf install clickhouse-server-<version>`).

### Binary tarball

- **Use for:** Hosts without a supported package manager, custom install layouts, dev environments, air-gapped installs.
- **Pros:** No package-manager assumptions; portable across distros.
- **Cons:** No automatic systemd integration, no package-manager upgrades, more manual.
- **Pinning rule:** Record the SHA256 of the tarball and the URL it came from.

> Source builds and other forms exist but are out of scope for this skill.

---

## Step 3 — Choose Architecture

Two common architectures. Confirm the target environment's architecture before recommending.

| Architecture | Aliases               | Common platforms                                         |
|--------------|------------------------|----------------------------------------------------------|
| **x86_64**   | `amd64`                | Intel and AMD servers; most cloud VMs; most laptops      |
| **aarch64**  | `arm64`                | Apple Silicon Macs, AWS Graviton, Ampere, Raspberry Pi 4/5, ARM-based servers |

How to detect:

```bash
uname -m        # x86_64 or aarch64
docker info --format '{{.Architecture}}'      # for the Docker daemon
kubectl get nodes -o wide                     # ARCHITECTURE column
```

> Other architectures (ppc64le, riscv64, s390x) may have community or experimental coverage; treat as not supported in this skill unless the user explicitly confirms availability and accepts the risk.

---

## Step 4 — Resolve Coverage Matrix

Not every flavor × form × architecture combination exists. Use the matrix below as a starting point, **but always verify availability against the canonical source before recommending** — coverage changes over time.

| Flavor                  | Container (x86_64) | Container (aarch64) | DEB (x86_64) | DEB (aarch64) | RPM (x86_64) | RPM (aarch64) | Tarball (x86_64) | Tarball (aarch64) |
|-------------------------|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| ClickHouse Official     | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Altinity Antalya        | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Altinity Stable         | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Altinity FIPS           | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

Legend: ✅ = generally available; ⚠️ = verify against current Altinity / ClickHouse documentation before committing.

If the requested combination is `⚠️` or absent, surface that to the user and offer the closest available alternative (typically: same flavor, different distribution form; or same form, different flavor).

---

## Step 5 — Find Latest Available Versions

When the user has not pinned a specific version — or asks "what's the latest?" — discover available versions by querying GitHub releases. The script `assets/find-latest-versions.sh` automates this. It is also useful as a standalone capability when the user is just exploring.

> **"Latest" means highest version number, not most recently published.** The script sorts results by version (descending), not by publication date. This matters for Altinity Stable in particular, where older lines (e.g. 24.8 LTS) receive ongoing patch backports concurrently with newer-line work — so the most recently published tag may not be the highest version. If the user explicitly asks for "the most recent patch on line X," look it up directly on GitHub rather than from this script's top result.

### Use cases

- **Standalone:** "What's the latest ClickHouse version?" or "What Altinity Antalya releases are out?" Run the script directly and report results.
- **In a deploy flow:** When `altinity-deploy-clickhouse-overview` hands off without a pinned version, run the script for the chosen flavor and propose the highest-version matching tag, then confirm with the user before locking it into the output contract.

### Run

```bash
# All flavors, top tag each by version (default).
./assets/find-latest-versions.sh

# Single flavor.
./assets/find-latest-versions.sh antalya

# Top N by version per flavor.
COUNT=5 ./assets/find-latest-versions.sh stable
```

The script uses `gh` CLI when available (higher rate limits when authenticated) and falls back to unauthenticated `curl`. Required dependencies: `bash` 4+, `jq`, `sort` with `-V` (GNU coreutils; macOS BSD sort supports `-V` since ~10.12), and either `gh` or `curl`. If a dependency is missing, the script prints a clear error and exits with code 2.

### Output

One row per match, tab-aligned:

```
<flavor>   <tag>                                   <published_date>  <release_url>
official   v26.3.10.60-lts                         2026-05-08        https://github.com/ClickHouse/ClickHouse/releases/tag/v26.3.10.60-lts
antalya    v25.8.22.20001.altinityantalya          2026-05-05        https://github.com/Altinity/ClickHouse/releases/tag/v25.8.22.20001.altinityantalya
stable     v24.8.14.10546.altinitystable           2026-05-08        https://github.com/Altinity/ClickHouse/releases/tag/v24.8.14.10546.altinitystable
fips       v25.3.8.30001.altinityfips              2026-04-15        https://github.com/Altinity/ClickHouse/releases/tag/v25.3.8.30001.altinityfips
```

### Interpreting the result

The tag name is the source of truth for the version. Strip the leading `v` and any flavor suffix to get the bare version (e.g. `v25.8.22.20001.altinityantalya` → version `25.8.22.20001`).

**FIPS access caveat.** Tags are published on public GitHub, but the actual FIPS-validated artifacts (containers, RPMs, etc.) are *not* supported unless you have a subcription from Altinity that includes FIPS support. The tag tells you the latest version exists; confirm with Altinity before using in any system that requires vendor support. 

### Exit codes

| Code | Meaning                                              |
|------|------------------------------------------------------|
| 0    | Success; at least one match printed.                 |
| 1    | Usage error (unknown flavor argument).               |
| 2    | Required dependency missing (`jq`, `gh`/`curl`).     |
| 3    | GitHub query failed for at least one flavor (network or rate limit). |
| 4    | No matching tags found for the requested flavor.     |

Treat exit codes 3 and 4 as soft failures during a deploy flow — fall back to asking the user for an explicit version rather than guessing.

### Maintenance

The repos and tag-pattern regexes live near the top of the script. If a query starts returning zero matches, the most likely cause is that the upstream tag convention changed; update the relevant pattern.

---

## Step 6 — Resolve Concrete Coordinates

Output the concrete reference the installer needs.

### Container images

| Flavor              | Image repository                          | Tag pattern                                           |
|---------------------|-------------------------------------------|-------------------------------------------------------|
| ClickHouse Official | `clickhouse/clickhouse-server`            | `<version>` (e.g. `24.8.14.10459`)                    |
| ClickHouse Official Keeper | `clickhouse/clickhouse-keeper`     | `<version>`                                           |
| Altinity Stable     | `altinity/clickhouse-server`              | `<version>.altinitystable`                            |
| Altinity Stable Keeper | `altinity/clickhouse-keeper`           | `<version>.altinitystable`                            |
| Altinity Antalya    | `altinity/clickhouse-server`              | `<version>.altinityantalya`                           |
| Altinity FIPS       | `altinity/clickhouse-server`              | `<version>.altinityfips`                              |

### Linux package repositories

| Flavor              | Repo (DEB / RPM)                  |
|---------------------|-----------------------------------|
| ClickHouse Official | `https://packages.clickhouse.com` |
| Altinity Stable     | `https://builds.altinity.cloud`   |
| Altinity Antalya    | `https://builds.altinity.cloud`   |
| Altinity FIPS       | `https://builds.altinity.cloud`   |

### Binary tarballs

Tarballs live alongside packages on the same hosts:

- ClickHouse Official: `https://packages.clickhouse.com/tgz/`
- Altinity Stable: `https://builds.altinity.cloud/stable-tgz-repo`
- Altinity Antalya : `https://builds.altinity.cloud/antalya-tgz-repo`
- Altinity FIPS : `https://builds.altinity.cloud/fips-tgz-repo`

> All paths above can move between releases. Verify URLs at install time and pin to a specific version. If any path is unreachable from the install environment, surface that to the user before continuing.

---

## Step 7 — Sanity Checks

Run the following automatically and report results before handing off:

1. **Registry / repo reachability** — DNS resolves, HTTPS responds.
2. **Image tag exists** — for container forms, confirm the resolved tag is pullable. Example:
   ```bash
   docker manifest inspect <fully-qualified-tag>
   ```
3. **Architecture match** — confirm the resolved tag publishes a manifest for the target architecture (multi-arch manifests should list both `amd64` and `arm64` where applicable).
4. **Package version exists** — for package forms, confirm via `apt-cache madison` / `dnf list available`.
5. **Tarball SHA256** — for tarball form, fetch the published checksum and record it.
6. **Version recency** — flag if the chosen version is more than 6 months behind the current Altinity Stable line (or upstream, for Official).
7. **FIPS compliance gate** — if FIPS is selected, confirm with the user that they have read the FIPS support matrix and understand the constrained feature surface.

If any check fails, stop and report — do not pass an unverified reference downstream.

---

## Output Contract

Hand the installer skill a structured summary:

```
build_flavor:       official | antalya | altinity-stable | altinity-fips
version:            <e.g. 24.8.14.10459>
distribution_form:  container | deb | rpm | tarball
architecture:       x86_64 | aarch64
server_image:       <fully-qualified image tag>     (container only)
keeper_image:       <fully-qualified image tag>     (container only)
package_repo:       <URL>                           (deb/rpm only)
package_version:    <pinned package version>       (deb/rpm only)
tarball_url:        <URL>                           (tarball only)
tarball_sha256:     <hex>                           (tarball only)
intent:             production | development
notes:              <flags from sanity checks; FIPS acknowledgment if applicable>
```

Downstream skills must use these exact values — no substitution.
