#!/usr/bin/env bash
# Portable timeout wrapper (macOS has no coreutils `timeout`).
# usage: with_timeout.sh SECONDS command [args...]
secs="$1"; shift
"$@" & pid=$!
( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) & wd=$!
wait "$pid"; rc=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
exit $rc
