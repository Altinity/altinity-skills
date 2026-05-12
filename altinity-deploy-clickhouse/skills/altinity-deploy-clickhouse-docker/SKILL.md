---
name: altinity-deploy-clickhouse-docker
description: Deploys ClickHouse using Docker Compose with one ClickHouse server and one Keeper. Designed to be extended to multi-shard / multi-replica clusters. Use for development, demo, and small production Docker stacks.
author: Altinity Inc
version: 0.0.1
license: Apache-2.0
---

# Deploy ClickHouse — Docker Compose

Stand up a working ClickHouse instance with an embedded-style Keeper using `docker compose`. The compose file ships one `clickhouse-server` and one `clickhouse-keeper` so the cluster is real (Keeper-backed) but minimal. Add shards/replicas by extending the compose file later.

---

## Action Mode

Hybrid:

- Read-only checks (`docker version`, `docker info`, port probes, `docker ps`) run automatically.
- Mutating steps (`docker compose up -d`, creation of `./data/` subdirectories, `chown` of the data tree on Linux, image pulls of large size) require explicit user confirmation. Print the exact command first. The `chown -R 101:101 data/` step requires `sudo` on Linux — call this out before running.

---

## Step 1 — Verify Inputs

Confirm with the user (or take from `altinity-deploy-clickhouse-overview` / `-builds` output):

- **Deployment intent** — production or development/demo?
- **ClickHouse server image** — fully-qualified tag from `altinity-deploy-clickhouse-builds`.
- **Keeper image** — fully-qualified tag from `altinity-deploy-clickhouse-builds`.
- **Install directory** — where the compose project will live (default: current working directory).
- **Default user password** — required for production; can be empty for development.

If any input is missing, ask. Do not proceed with placeholder values.

---

## Step 2 — Verify the Host

Run automatically:

```bash
docker version
docker info --format '{{.ServerVersion}}'
docker compose version
```

Confirm:

- Docker daemon is running.
- Compose v2 is available (`docker compose`, not the legacy `docker-compose`).
- Ports 8123 (HTTP), 9000 (native), and 9181 (Keeper client) are free on the host.

If Docker is missing or the daemon is not running, stop and ask the user to install or start Docker.

---

## Step 3 — Materialize the Compose Project

The `assets/` directory in this skill contains:

- `docker-compose.yml` — Compose stack with placeholders for image tags and the default password.
- `config.d/keeper.xml` — server-side `<zookeeper>` config pointing at the Keeper service.
- `config.d/macros.xml` — `<macros>` for shard / replica naming (single-node defaults).
- `config.d/listen.xml` — binds the server to all interfaces inside the container so Docker NAT can reach it. External exposure is still controlled by the published-port binding in `docker-compose.yml`.
- `users.d/default-password.xml` — sets the default user password (production only).
- `keeper-config.xml` — Keeper standalone config.
- `README.md` — user-facing operations doc explaining what the install is and how to start / stop / connect to ClickHouse and Keeper. Copy as-is; no placeholder substitution.

The compose file uses **bind mounts under `./data/`** for all persistent state — not Docker named volumes. Layout under the install directory after Step 3 completes:

```
<install-dir>/
├── README.md                        ← operations doc for the installed stack
├── docker-compose.yml
├── keeper-config.xml
├── config.d/
│   ├── keeper.xml
│   ├── listen.xml
│   └── macros.xml
├── users.d/
│   └── default-password.xml         (production only)
└── data/                            ← all persistent state lives here
    ├── clickhouse/                  → /var/lib/clickhouse
    ├── clickhouse-logs/             → /var/log/clickhouse-server
    ├── keeper/                      → /var/lib/clickhouse-keeper
    └── keeper-logs/                 → /var/log/clickhouse-keeper
```

Procedure:

1. Copy `assets/` contents into the install directory.
2. Substitute placeholders:
   - `${CH_SERVER_IMAGE}` — server image tag from build skill.
   - `${CH_KEEPER_IMAGE}` — Keeper image tag from build skill.
   - `${CH_DEFAULT_PASSWORD}` — production only; remove the `users.d/default-password.xml` for development.
3. Create the `data/` subdirectories and set ownership so the in-container `clickhouse` user (UID/GID 101) can write to them:
   ```bash
   mkdir -p data/clickhouse data/clickhouse-logs data/keeper data/keeper-logs

   # Linux: bind-mount targets created by Docker default to root:root.
   # Align them with the clickhouse user inside the image so the server
   # and Keeper can read/write their data and log directories.
   if [ "$(uname)" = "Linux" ]; then
       sudo chown -R 101:101 data/
   fi
   # On macOS / Windows Docker Desktop, the file-sharing layer maps
   # ownership for you — the chown step is a no-op there.
   ```
4. If the install directory is under version control, add `data/` to `.gitignore` — it will accumulate large amounts of state and should never be committed.
5. Show the user the materialized compose file before starting anything.

---

## Step 4 — Production vs Development Defaults

| Setting               | Development                          | Production                                   |
|-----------------------|--------------------------------------|----------------------------------------------|
| Image tag             | Pinned stable acceptable             | Pinned Altinity Stable Build version         |
| Default user password | Empty (omit `users.d/default-password.xml`) | Strong password set via `users.d/default-password.xml` |
| Persistent storage    | Bind mounts under `./data/`          | Bind mounts under `./data/`; back up `./data/` regularly and document the schedule |
| Restart policy        | `unless-stopped`                     | `unless-stopped`                             |
| Resource limits       | None                                 | `deploy.resources.limits.{cpus,memory}` set  |
| Bind address          | `127.0.0.1`                          | Restrict via host firewall; document exposure |
| TLS                   | Off                                  | Out of scope for MVP — flag as follow-up     |

When in production mode, set resource limits in the compose file before bringing the stack up. Even rough values (e.g. 4 CPU / 8 GiB) beat unlimited.

---

## Step 5 — Bring the Stack Up

After confirmation:

```bash
docker compose pull
docker compose up -d
```

Then poll readiness:

```bash
docker compose ps
docker compose logs --tail=50 clickhouse
```

Wait until `clickhouse` reports `Ready for connections` and `keeper` reports it has joined or formed quorum.

---

## Step 6 — Validate

Hand off to `altinity-deploy-clickhouse-smoke-test` against the new endpoint:

- Host: `localhost`
- HTTP port: `8123`
- Native port: `9000`
- User: `default`
- Password: as set above (empty for dev)

Do not declare success until smoke tests pass.

Once smoke tests pass, point the user at `<install-dir>/README.md` for day-to-day operations — it documents starting, stopping, wiping, and connecting to ClickHouse and Keeper. The README is the durable doc the user keeps; this SKILL.md is the one-time install procedure.

---

## Extending Later

This compose file is a single-node cluster on purpose — Keeper is real, macros are set, replication tables will work. To extend:

- Add additional `clickhouse-N` services with distinct macros and a shared Keeper.
- For HA Keeper, scale Keeper to 3 nodes (separate skill — out of MVP scope).
- For multi-host, switch to Swarm or move to the Kubernetes skill.

## Persistence and Cleanup

State lives under `./data/` (bind mounts), not in Docker named volumes. This means:

- `docker compose down` stops the containers but **leaves `./data/` intact** — restart with `docker compose up -d` and your tables come back.
- `docker compose down -v` is a no-op for state since there are no named volumes; data still persists.
- To **wipe state and start fresh**:
  ```bash
  docker compose down
  # On Linux the data tree is owned by 101:101 (clickhouse), so removal needs sudo.
  if [ "$(uname)" = "Linux" ]; then sudo rm -rf data/; else rm -rf data/; fi
  # Re-create empty subdirs and ownership exactly as in Step 3 before bringing the stack back up.
  ```
- For backup, archive `./data/` while the stack is stopped (or use `clickhouse-backup` for hot backups — out of MVP scope).

---

## Cross-Module Triggers

| After this skill runs | Next skill                              |
|-----------------------|-----------------------------------------|
| Stack is up           | `altinity-deploy-clickhouse-smoke-test` |
| Production intent     | Flag TLS, RBAC, backup as follow-ups (skills planned) |
