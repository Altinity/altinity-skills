#!/usr/bin/env bash
# Start / stop throwaway ClickHouse containers for the SQL version matrix.
#
#   containers.sh up 24.8 25.8 26.8      start one container per version
#   containers.sh down 24.8 25.8 26.8    remove them
#   containers.sh endpoints 24.8 25.8    print LABEL=host:port lines for sql_matrix.py
#   containers.sh status                 list running matrix containers
#
# Port scheme: native = 9200 + (major % 10) * 10 + minor  (24.8 -> 9248, 26.9 -> 9269)
#              http   = 8200 + (major % 10) * 10 + minor
# Containers mount tests/clickhouse-server/{config.d,users.d}, which turn the
# server into a one-node replicated cluster with embedded Keeper and enable the
# optional system log tables.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HERE/.." && pwd)"
CONF_DIR="$TESTS_DIR/clickhouse-server"
IMAGE="${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server}"
BIND="${MATRIX_BIND:-127.0.0.1}"
PREFIX="skillmatrix-ch"

port_for() {
    local ver="$1" kind="$2"
    local major="${ver%%.*}" minor="${ver#*.}"
    minor="${minor%%.*}"
    local base=9200
    [[ "$kind" == "http" ]] && base=8200
    echo $(( base + (major % 10) * 10 + minor ))
}

wait_ready() {
    local name="$1" tries=60
    while (( tries-- > 0 )); do
        if docker exec "$name" clickhouse-client -q "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "container $name did not become ready" >&2
    docker logs --tail 40 "$name" >&2 || true
    return 1
}

# System log tables are created lazily on first flush. Create a MergeTree table,
# a materialized view and a ReplicatedMergeTree table, insert, and flush so that
# part_log, query_views_log, query_log, text_log, session_log and system.replicas
# have content for the matrix. The tables are kept.
warmup() {
    local name="$1"
    docker exec "$name" clickhouse-client --multiquery -q "
        CREATE DATABASE IF NOT EXISTS matrix_warmup;
        CREATE TABLE IF NOT EXISTS matrix_warmup.events (d Date, x UInt64, s String) ENGINE = MergeTree PARTITION BY d ORDER BY x;
        CREATE MATERIALIZED VIEW IF NOT EXISTS matrix_warmup.events_mv ENGINE = SummingMergeTree ORDER BY d AS SELECT d, count() AS c FROM matrix_warmup.events GROUP BY d;
        INSERT INTO matrix_warmup.events SELECT today() - number % 3, number, toString(number) FROM numbers(3000);
        INSERT INTO matrix_warmup.events SELECT today(), number, 'x' FROM numbers(100);
        CREATE TABLE IF NOT EXISTS matrix_warmup.replicated (x UInt64) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/matrix_warmup_replicated', '{replica}') ORDER BY x;
        INSERT INTO matrix_warmup.replicated SELECT number FROM numbers(100);
        SELECT count() FROM matrix_warmup.events WHERE x > 10 FORMAT Null;
        SYSTEM FLUSH LOGS;
    " >/dev/null 2>&1 || echo "warmup failed for $name (continuing)" >&2
}

cmd="${1:-}"; shift || true
case "$cmd" in
    up)
        for v in "$@"; do
            name="$PREFIX-$v"
            tcp="$(port_for "$v" tcp)"; http="$(port_for "$v" http)"
            if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
                docker rm -f "$name" >/dev/null
            fi
            echo "starting $name ($IMAGE:$v) on $BIND:$tcp (native) / $BIND:$http (http)"
            # Mount config files one by one: mounting the whole config.d would hide the
            # image's docker_related_config.xml (listen_host) and break published ports.
            mounts=()
            for f in "$CONF_DIR"/config.d/*.xml; do
                mounts+=(-v "$f:/etc/clickhouse-server/config.d/$(basename "$f"):ro")
            done
            for f in "$CONF_DIR"/users.d/*.xml; do
                mounts+=(-v "$f:/etc/clickhouse-server/users.d/$(basename "$f"):ro")
            done
            docker run -d --name "$name" \
                -p "$BIND:$tcp:9000" -p "$BIND:$http:8123" \
                -e CLICKHOUSE_SKIP_USER_SETUP=1 \
                "${mounts[@]}" \
                --ulimit nofile=262144:262144 \
                "$IMAGE:$v" >/dev/null
        done
        for v in "$@"; do
            wait_ready "$PREFIX-$v"
            warmup "$PREFIX-$v"
            ver="$(docker exec "$PREFIX-$v" clickhouse-client -q "SELECT version()")"
            echo "ready: $PREFIX-$v -> $ver"
        done
        ;;
    down)
        for v in "$@"; do
            docker rm -f "$PREFIX-$v" >/dev/null 2>&1 && echo "removed $PREFIX-$v" || true
        done
        ;;
    endpoints)
        for v in "$@"; do
            echo "$v=$BIND:$(port_for "$v" tcp)"
        done
        ;;
    status)
        docker ps --filter "name=$PREFIX-" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
        ;;
    *)
        sed -n '2,15p' "$0"
        exit 1
        ;;
esac
