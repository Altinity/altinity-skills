#!/usr/bin/env bash
# Re-run assert_run.py over every finished run under a suite directory (after
# changing the assertion logic), keeping arm/skill/wall/exit from the previous
# assertions.json.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HERE/.." && pwd)"
root="${1:?suite dir}"
for d in "$root"/*/; do
    [[ -f "$d/assertions.json" && -f "$d/run.ndjson" ]] || continue
    arm=$(jq -r .arm "$d/assertions.json"); skill=$(jq -r .skill "$d/assertions.json")
    wall=$(jq -r .wall_seconds "$d/assertions.json"); rc=$(jq -r .exit_code "$d/assertions.json"); label=$(jq -r .label "$d/assertions.json")
    exp="$TESTS_DIR/$skill/expected.md"
    python3 "$HERE/assert_run.py" "$d/run.ndjson" --arm "$arm" --skill "$skill" ${exp:+--expected "$exp"} \
        --report-out "$d/report.md" --json-out "$d/assertions.json" --wall-seconds "$wall" --exit-code "$rc" --label "$label" > "$d/summary.txt"
done
python3 "$HERE/summarize.py" "$root" | tee "$root/summary.md"
