#!/bin/sh
set -eu

helper=$1
normal=$($helper --worker-info)
printf '%s' "$normal" | grep '"protocol_version":3' >/dev/null

fifo=${TMPDIR:-/tmp}/sayall-worker-info-wait-$$
output=$fifo.out
trap 'rm -f "$fifo" "$output"' EXIT
mkfifo "$fifo"
exec 3<>"$fifo"
"$helper" --worker-info --wait <&3 >"$output" &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep '"protocol_version":3' "$output" >/dev/null 2>&1 && break
    sleep 0.05
done
grep '"protocol_version":3' "$output" >/dev/null
kill -0 "$pid"
printf x >&3
exec 3>&-
wait "$pid"
