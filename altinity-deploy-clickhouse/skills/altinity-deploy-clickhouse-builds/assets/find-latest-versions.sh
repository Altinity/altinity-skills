#!/usr/bin/env bash
#
# find-latest-versions.sh
#
# Discover the latest ClickHouse build versions by querying GitHub releases.
# Prints one line per matching tag, sorted by version number (highest first).
#
# Note: "highest version" is determined by version-sort on the tag, NOT by
# publication date. For Altinity Stable in particular, older lines (e.g. 24.8
# LTS) receive ongoing patch backports, so the most-recently-published tag may
# not be the highest version number. This script returns the highest version.
#
# Usage:
#   ./find-latest-versions.sh                    # all flavors, top 1 each
#   ./find-latest-versions.sh official           # only ClickHouse Official
#   ./find-latest-versions.sh stable             # only Altinity Stable
#   ./find-latest-versions.sh antalya            # only Altinity Antalya
#   ./find-latest-versions.sh fips               # only Altinity FIPS
#   COUNT=5 ./find-latest-versions.sh stable     # show top 5 by version number
#   ARCH=aarch64 ./find-latest-versions.sh       # filter to aarch64 (info only)
#
# Auth:
#   Uses `gh` CLI if available (higher rate limits when authenticated).
#   Falls back to unauthenticated `curl` (60 req/hr; sufficient for single
#   lookups but will rate-limit on repeated `all` calls).
#
# Dependencies:
#   - bash 4+ (associative arrays)
#   - curl OR gh
#   - jq
#
# Output contract:
#   <flavor>  <tag>  <published_at>  <html_url>
#
# Exit codes:
#   0 success (at least one match printed)
#   1 usage error
#   2 dependency missing
#   3 GitHub query failed for at least one flavor
#   4 no matching tags found

set -euo pipefail

#-----------------------------------------------------------------------------
# Configuration — VERIFY before relying on these in production.
# Repos and tag patterns can change over time. If a query returns nothing,
# the most likely cause is that the pattern below no longer matches the
# current release tags.
#-----------------------------------------------------------------------------

declare -A REPOS=(
    [official]="ClickHouse/ClickHouse"
    [stable]="Altinity/ClickHouse"
    [antalya]="Altinity/ClickHouse"
    [fips]="Altinity/ClickHouse"
)

declare -A TAG_PATTERNS=(
    # Patterns use awk extended regex; [.] matches a literal dot.
    # Upstream tags look like v24.8.14.10459-stable or v25.1.1.123-lts.
    [official]='^v[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+(-(stable|lts|prestable|testing))?$'
    # Altinity Stable tags carry an .altinitystable suffix.
    [stable]='[.]altinitystable$'
    # Altinity Antalya tags carry an .altinityantalya suffix.
    [antalya]='[.]altinityantalya$'
    # Altinity FIPS tags carry an .altinityfips suffix.
    [fips]='[.]altinityfips$'
)

#-----------------------------------------------------------------------------

COUNT="${COUNT:-1}"
ARCH="${ARCH:-}"
FLAVOR="${1:-all}"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' is required but not found in PATH." >&2
        exit 2
    }
}

require jq
if ! command -v gh >/dev/null 2>&1; then
    require curl
fi

fetch_releases() {
    local repo="$1"
    if command -v gh >/dev/null 2>&1; then
        gh api -H "Accept: application/vnd.github+json" \
            "/repos/${repo}/releases?per_page=100"
    else
        curl -fsS -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${repo}/releases?per_page=100"
    fi
}

print_flavor() {
    local flavor="$1"
    local repo="${REPOS[$flavor]:-}"
    local pattern="${TAG_PATTERNS[$flavor]:-}"

    if [[ -z "$repo" ]]; then
        printf '%-9s  (no public GitHub repo configured — verify with Altinity)\n' "$flavor"
        return
    fi

    local json
    if ! json=$(fetch_releases "$repo" 2>/dev/null); then
        printf '%-9s  ERROR querying %s (rate-limited or network failure)\n' "$flavor" "$repo" >&2
        FAILED=1
        return
    fi

    # Emit tab-separated rows: tag\tpublished_at\thtml_url, then filter on
    # the tag (first column) only so URL/date contents can't accidentally
    # match the pattern. Sort version-descending on the tag column so the
    # highest version number is first (NOT the most recently published).
    local rows
    rows=$(echo "$json" \
        | jq -r '.[] | [.tag_name, .published_at, .html_url] | @tsv' \
        | awk -F'\t' -v pat="$pattern" '$1 ~ pat' \
        | sort -t$'\t' -k1,1 -V -r \
        | head -n "$COUNT" || true)

    if [[ -z "$rows" ]]; then
        printf '%-9s  no tags matched pattern: %s\n' "$flavor" "$pattern"
        NO_MATCH=$((NO_MATCH + 1))
        return
    fi

    while IFS=$'\t' read -r tag published_at url; do
        printf '%-9s  %-40s  %s  %s\n' "$flavor" "$tag" "${published_at%T*}" "$url"
        FOUND=$((FOUND + 1))
    done <<< "$rows"
}

FOUND=0
NO_MATCH=0
FAILED=0

case "$FLAVOR" in
    all)
        for f in official antalya stable fips; do
            print_flavor "$f"
        done
        ;;
    official|antalya|stable|fips)
        print_flavor "$FLAVOR"
        ;;
    -h|--help)
        sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
        exit 0
        ;;
    *)
        echo "error: unknown flavor: $FLAVOR" >&2
        echo "usage: $0 [official|antalya|stable|fips|all]" >&2
        exit 1
        ;;
esac

if [[ -n "$ARCH" ]]; then
    echo
    echo "note: ARCH=$ARCH set; this script reports tags only — confirm architecture coverage"
    echo "      via the registry / repo (e.g. 'docker manifest inspect <image>')."
fi

if [[ "$FAILED" -eq 1 ]]; then
    exit 3
fi
if [[ "$FOUND" -eq 0 ]]; then
    exit 4
fi
exit 0
