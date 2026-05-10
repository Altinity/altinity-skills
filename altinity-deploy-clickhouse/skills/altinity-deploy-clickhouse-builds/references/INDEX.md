# Documentation References — ClickHouse Build Selection

Canonical sources Claude should consult to verify facts that change over time
(repo paths, supported architectures, distribution coverage, FIPS support
matrix, current versions). Each entry is a pointer; fetch the URL with
`WebFetch` when current data is needed.

---

## Build Flavors

### Altinity Antalya Builds — feature-forward Altinity track
- **Landing / overview:** https://altinity.com/blog/getting-started-with-altinitys-project-antalya
- **Documentation:** https://docs.altinity.com/altinityantalya/
- **GitHub releases (Antalya tags):** https://github.com/Altinity/ClickHouse/releases?q=altinityantalya
- **Use when:** user asks about Antalya feature scope (OAuth/OIDC, swarm clusters, Iceberg/Parquet reads, tiered storage to Iceberg), version cadence, or upstream-compatibility statement.

### Altinity Stable Builds — long-term-support Altinity track
- **Landing:** https://altinity.com/altinity-stable/
- **Documentation:** https://docs.altinity.com/altinitystablebuilds/
- **GitHub releases (Stable tags):** https://github.com/Altinity/ClickHouse/releases?q=altinitystable
- **Use when:** user asks about supported Stable lines, support window, qualification process, security backports, EOL dates.

### Altinity FIPS Builds — FIPS 140-3 compatible Altinity track
- **Landing page and documentation:** https://docs.altinity.com/altinitystablebuilds/fips-compatible-altinity-builds/
- **GitHub releases (FIPS tags):** https://github.com/Altinity/ClickHouse/releases?q=altinityfips
- **Use when:** user asks about FIPS 140-3 scope, validated module identity, supported feature surface, subscription requirements, compliance evidence.

### ClickHouse Official Builds — upstream from ClickHouse, Inc.
- **Documentation root:** https://clickhouse.com/docs
- **Release notes / changelog:** https://clickhouse.com/docs/whats-new/changelog
- **GitHub releases:** https://github.com/ClickHouse/ClickHouse/releases
- **Use when:** user asks about upstream version policy, LTS tags, feature availability per upstream version, EOL.

---

## Artifact Locations

### Container registries
- **Altinity server image:** https://hub.docker.com/r/altinity/clickhouse-server
- **Altinity Keeper image:** https://hub.docker.com/r/altinity/clickhouse-keeper
- **ClickHouse Inc. server image:** https://hub.docker.com/r/clickhouse/clickhouse-server
- **ClickHouse Inc. Keeper image:** https://hub.docker.com/r/clickhouse/clickhouse-keeper
- **Use when:** verifying that a tag exists, listing available tags by flavor suffix, or confirming multi-arch coverage.

### Package & tarball repositories
- **ClickHouse Inc. packages:** https://packages.clickhouse.com
- **ClickHouse Inc. install docs:** https://clickhouse.com/docs/install
- **Altinity build host (DEB / RPM / tarball):** https://builds.altinity.cloud
- **Altinity install / packaging docs:** https://docs.altinity.com/altinitystablebuilds/stablequickstartguide/
- **Use when:** configuring apt/yum/dnf repos, downloading tarballs, or finding the canonical install command for a given OS.

### GitHub source / release tracking
- **ClickHouse, Inc. repo:** https://github.com/ClickHouse/ClickHouse
- **Altinity ClickHouse repo (Stable, Antalya, FIPS releases):** https://github.com/Altinity/ClickHouse
- **Altinity clickhouse-operator (K8s):** https://github.com/Altinity/clickhouse-operator
- **Use when:** discovering latest tags, reading release notes, or locating a specific commit / SHA.

---

## Architecture & Build Support

- **ClickHouse system requirements:** https://clickhouse.com/docs/install#system-requirements
- **ClickHouse supported platforms / OS:** https://clickhouse.com/docs/operations/tips
- **Altinity build support matrix:** https://docs.altinity.com/altinitystablebuilds/
- **Use when:** user asks whether a specific OS, kernel version, or architecture is supported; or whether multi-arch images cover their target.

---

## Compliance & Support

### FIPS 140-3 background
- **NIST CMVP program (validations search):** https://csrc.nist.gov/projects/cryptographic-module-validation-program
- **NIST FIPS 140-3 standard:** https://csrc.nist.gov/publications/detail/fips/140/3/final
- **Use when:** explaining what FIPS 140-3 means, validating a vendor's certificate number, or confirming that a specific cryptographic module is in-scope.

### Altinity support
- **Altinity support / subscriptions:** https://altinity.com/support/
- **Altinity contact for FIPS-specific questions:** https://altinity.com/contact
- **Use when:** user asks about commercial support coverage, subscription tiers, or FIPS-validated artifact access.

### Altinity Cloud
- **Altinity BYOC cloud subscriptions:** (Runs in user account) https://altinity.com/managed-clickhouse/bring-your-own-cloud/
- **Altinity SaaS cloud subscriptions:** (Runs in Altinity account) https://altinity.com/managed-clickhouse/
- **Altinity contact for cloud-specific questions:** https://altinity.com/contact
- **Use when:** User asks for an Altinity-managed service for ClickHouse, BYOC vs. SaaS choice, cloud subscription tiers. 

---

## Latest-Version Discovery

The `assets/find-latest-versions.sh` script in this skill is the primary
mechanism for discovering current versions across all four flavors. It
queries GitHub releases directly. See `SKILL.md` Step 5 for usage.

---

## Maintenance

When a `(verify)` link is confirmed (or corrected), remove the marker.
When a link returns 404 or redirects unexpectedly, replace it with the
current canonical URL and note the change in the commit message.
