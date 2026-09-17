#!/usr/bin/env bash
# Run the OpenCode evaluation suite: several skills x several arms against one
# ClickHouse endpoint, then summarize.
#
#   run_suite.sh --model provider/model --ch-host H --ch-port P --out DIR \
#                --arms "none new" --skills "overview merges memory" \
#                [--new-skills DIR] [--old-skills DIR] [--parallel 2] [--timeout 900] [--label 25.8]
#
# Arms: none (no skills), old (skills from --old-skills), new (skills from --new-skills,
# default: ../../skills). Test fixtures are expected to exist already
# (tests/runner/run-test.sh --setup-only <skill>); --focus-db defaults to the test DB name.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HERE/.." && pwd)"
MODEL="" CH_HOST="127.0.0.1" CH_PORT="9000" OUT="" ARMS="none new" SKILLS="overview" NEW_SKILLS="$TESTS_DIR/../skills" OLD_SKILLS="" PARALLEL=1 TIMEOUT=900 LABEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2;;
        --ch-host) CH_HOST="$2"; shift 2;;
        --ch-port) CH_PORT="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        --arms) ARMS="$2"; shift 2;;
        --skills) SKILLS="$2"; shift 2;;
        --new-skills) NEW_SKILLS="$2"; shift 2;;
        --old-skills) OLD_SKILLS="$2"; shift 2;;
        --parallel) PARALLEL="$2"; shift 2;;
        --timeout) TIMEOUT="$2"; shift 2;;
        --label) LABEL="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 2;;
    esac
done
[[ -n "$MODEL" && -n "$OUT" ]] || { sed -n '2,12p' "$0"; exit 2; }
mkdir -p "$OUT"

jobs=()
for skill in $SKILLS; do
    full="altinity-expert-clickhouse-$skill"
    expected="$TESTS_DIR/$full/expected.md"
    for arm in $ARMS; do
        case "$arm" in
            none) armflag="--arm none";;
            new)  armflag="--arm skills --skills-dir $NEW_SKILLS";;
            old)  [[ -n "$OLD_SKILLS" ]] || { echo "--old-skills required for arm old" >&2; exit 2; }; armflag="--arm skills --skills-dir $OLD_SKILLS";;
            *) echo "unknown arm $arm" >&2; exit 2;;
        esac
        dir="$OUT/${LABEL:+$LABEL-}$skill-$arm"
        jobs+=("$HERE/run_eval.sh $armflag --skill $full --model $MODEL --ch-host $CH_HOST --ch-port $CH_PORT --focus-db $full ${expected:+--expected $expected} --out $dir --timeout $TIMEOUT --label ${LABEL:+$LABEL-}$skill-$arm")
    done
done

echo "${#jobs[@]} runs, parallel=$PARALLEL"
running=0
for j in "${jobs[@]}"; do
    ( eval "$j" >/dev/null 2>&1 || true ) &
    running=$((running + 1))
    if (( running >= PARALLEL )); then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
    fi
done
wait
python3 "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.md"
