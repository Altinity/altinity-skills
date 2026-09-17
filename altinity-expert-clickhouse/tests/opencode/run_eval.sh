#!/usr/bin/env bash
# Run one OpenCode + model evaluation of a diagnostic skill against a ClickHouse
# server and score it deterministically.
#
#   run_eval.sh --arm none|skills --skills-dir DIR --skill NAME --model provider/model \
#               --ch-host H --ch-port P [--focus-db DB] [--expected FILE] \
#               --out DIR [--timeout SECONDS] [--label TEXT]
#
# --arm none    : no skills are made available; the model works from its own knowledge.
# --arm skills  : DIR is exposed as the project's .opencode/skills and the prompt names
#                 the connection skill and the skill under test.
#
# Artifacts in --out: project/ (scratch OpenCode project), run.ndjson (event stream),
# run.stderr, report.md (final assistant message), assertions.json, summary.txt.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="" SKILLS_DIR="" SKILL="" MODEL="" CH_HOST="127.0.0.1" CH_PORT="9000" FOCUS_DB="" EXPECTED="" OUT="" TIMEOUT=900 LABEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arm) ARM="$2"; shift 2;;
        --skills-dir) SKILLS_DIR="$(cd "$2" && pwd)"; shift 2;;
        --skill) SKILL="$2"; shift 2;;
        --model) MODEL="$2"; shift 2;;
        --ch-host) CH_HOST="$2"; shift 2;;
        --ch-port) CH_PORT="$2"; shift 2;;
        --focus-db) FOCUS_DB="$2"; shift 2;;
        --expected) EXPECTED="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2;;
        --out) OUT="$2"; shift 2;;
        --timeout) TIMEOUT="$2"; shift 2;;
        --label) LABEL="$2"; shift 2;;
        *) echo "unknown arg $1" >&2; exit 2;;
    esac
done
[[ -n "$ARM" && -n "$SKILL" && -n "$MODEL" && -n "$OUT" ]] || { sed -n '2,16p' "$0"; exit 2; }
[[ "$ARM" == "none" || -n "$SKILLS_DIR" ]] || { echo "--skills-dir required for --arm skills" >&2; exit 2; }
command -v opencode >/dev/null || { echo "opencode not found" >&2; exit 2; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
PROJ="$OUT/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/.opencode/agents"
sed "s#__MODEL__#$MODEL#" "$HERE/agent.md.tmpl" > "$PROJ/.opencode/agents/chdiag.md"
if [[ "$ARM" == "skills" ]]; then
    ln -s "$SKILLS_DIR" "$PROJ/.opencode/skills"
fi
( cd "$PROJ" && git init -q . 2>/dev/null || true )

SHORT="${SKILL#altinity-expert-clickhouse-}"
AREA="$(echo "$SHORT" | tr '-' ' ')"
CONN="clickhouse client --host $CH_HOST --port $CH_PORT --user default --query \"<SQL>\""
{
    echo "Diagnose ClickHouse ${AREA} health on the server reachable with this exact command form (no password, no TLS):"
    echo "  $CONN"
    if [[ -n "$FOCUS_DB" ]]; then
        echo "Focus on the database \`$FOCUS_DB\`, which contains the workload under investigation, but report server-wide problems too."
    fi
    if [[ "$ARM" == "skills" ]]; then
        if [[ "$SKILL" == "altinity-expert-clickhouse-connection" || "$SKILL" == "altinity-expert-clickhouse-overview" ]]; then
            echo "First use the altinity-expert-clickhouse-connection skill, then the altinity-expert-clickhouse-overview skill, following their instructions exactly."
        else
            echo "First use the altinity-expert-clickhouse-connection skill, then the ${SKILL} skill, following their instructions exactly."
        fi
    else
        echo "Use your own knowledge of ClickHouse system tables. Run only read-only SQL."
    fi
    echo "Write the final report as markdown in your last message. It must contain: a header with connection mode, cluster or single node, ClickHouse version and time window; a findings table with a severity (Critical, Major, Moderate, Minor or OK) per finding with specific numbers as evidence and a recommendation; a section \"Skipped and failed checks\" listing every query that errored or was skipped with the error text or reason; and a section \"Next steps\"."
} > "$OUT/prompt.txt"

START=$(date +%s)
set +e
( cd "$PROJ" && "$HERE/with_timeout.sh" "$TIMEOUT" opencode run --pure --agent chdiag --model "$MODEL" --format json "$(cat "$OUT/prompt.txt")" ) > "$OUT/run.ndjson" 2> "$OUT/run.stderr"
RC=$?
set -e
END=$(date +%s)

python3 "$HERE/assert_run.py" "$OUT/run.ndjson" --arm "$ARM" --skill "$SKILL" \
    ${EXPECTED:+--expected "$EXPECTED"} --report-out "$OUT/report.md" --json-out "$OUT/assertions.json" \
    --wall-seconds "$((END - START))" --exit-code "$RC" ${LABEL:+--label "$LABEL"} | tee "$OUT/summary.txt"
