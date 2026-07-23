#!/bin/sh
set -eu

if [ "$(uname -s)" != Linux ]; then
  echo 'daemon E2E tests skipped: Linux host required'
  exit 0
fi

sayall=$1
test_dir=$(mktemp -d /tmp/sayall-daemon-e2e.XXXXXX)
daemon_pid=
cleanup() {
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill -TERM -"$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/config/sayall" \
  "$test_dir/state" "$test_dir/runtime"
chmod 700 "$test_dir/home" "$test_dir/config" "$test_dir/state" "$test_dir/runtime"

cat >"$test_dir/bin/pw-record" <<'EOF'
#!/usr/bin/env python3
import pathlib
import signal
import sys
import time

signal.signal(signal.SIGINT, lambda _signum, _frame: sys.exit(0))
signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
pathlib.Path(sys.argv[-1]).write_bytes(b"\x01\x00\x02\x00")
while True:
    time.sleep(1)
EOF

cat >"$test_dir/bin/sayall-e2e-stt" <<'EOF'
#!/bin/sh
set -eu
test -s "$1"
printf '%s\n' "$1" >>"$SAYALL_E2E_STT_LOG"
cat <<'TRANSCRIPT'
Unicode café 🦊
Line two has 1.2.3 and $33.54
TRANSCRIPT
EOF

cat >"$test_dir/bin/wtype" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = "--" ]; then
  shift
  printf %s "$1" >"$SAYALL_E2E_TYPE_OUTPUT"
else
  printf '%s\n' "$*" >>"$SAYALL_E2E_WTYPE_LOG"
fi
EOF

cat >"$test_dir/bin/wl-copy" <<'EOF'
#!/bin/sh
set -eu
cat >"$SAYALL_E2E_CLIPBOARD_OUTPUT"
EOF
chmod +x "$test_dir/bin/pw-record" "$test_dir/bin/sayall-e2e-stt" \
  "$test_dir/bin/wtype" "$test_dir/bin/wl-copy"

expected=$test_dir/expected
printf 'Unicode café 🦊\nLine two has 1.2.3 and $33.54 ' >"$expected"

export HOME=$test_dir/home
export XDG_CONFIG_HOME=$test_dir/config
export XDG_STATE_HOME=$test_dir/state
export XDG_RUNTIME_DIR=$test_dir/runtime
export SAYALL_SOCKET=$test_dir/runtime/sayall.sock
export SAYALL_E2E_STT_LOG=$test_dir/stt.log
export SAYALL_E2E_TYPE_OUTPUT=$test_dir/type.out
export SAYALL_E2E_CLIPBOARD_OUTPUT=$test_dir/clipboard.out
export SAYALL_E2E_WTYPE_LOG=$test_dir/wtype.log
export PATH=$test_dir/bin:$PATH
unset DEEPGRAM_API_KEY GROQ_API_KEY SAYALL_STT_MODEL SAYALL_LLM_MODEL SAYALL_VERBOSE

write_config() {
  method=$1
  cat >"$test_dir/config/sayall/config.json" <<EOF
{"stt":{"streaming":false},"llm":{"enabled":false},"output":{"method":"$method","trailing_space":true},"recording":{"min_ms":0},"metrics":{"enabled":false},"notifications":false}
EOF
}

wait_for_status() {
  wanted=$1
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    status=$("$sayall" status 2>/dev/null || true)
    if [ "$status" = "$wanted" ]; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.02
  done
  echo "daemon did not reach $wanted (last status: ${status:-unreachable})" >&2
  return 1
}

start_daemon() {
  setsid "$sayall" daemon --verbose >"$test_dir/daemon.log" 2>&1 &
  daemon_pid=$!
  wait_for_status idle
}

stop_daemon() {
  timed_out=$test_dir/shutdown-timed-out
  rm -f "$timed_out"
  (
    sleep 2
    if kill -0 "$daemon_pid" 2>/dev/null; then
      : >"$timed_out"
      kill -KILL -"$daemon_pid" 2>/dev/null || true
    fi
  ) &
  guard_pid=$!
  kill -TERM -"$daemon_pid"
  wait "$daemon_pid" 2>/dev/null || true
  kill "$guard_pid" 2>/dev/null || true
  wait "$guard_pid" 2>/dev/null || true
  if [ -e "$timed_out" ]; then
    cat "$test_dir/daemon.log" >&2
    echo 'daemon process group did not shut down within 2 seconds' >&2
    exit 1
  fi
  daemon_pid=
}

wait_for_recording_data() {
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    if find "$test_dir/runtime" -maxdepth 1 -name 'sayall-rec-*.pcm' -size +0c | grep -q .; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.02
  done
  echo 'fake recorder did not produce audio data' >&2
  return 1
}

run_session() {
  test "$("$sayall" status)" = idle
  test "$("$sayall" toggle --raw)" = recording
  test "$("$sayall" status)" = recording
  wait_for_recording_data
  test "$("$sayall" toggle --raw)" = processing
  wait_for_status idle
  test -z "$(find "$test_dir/runtime" -maxdepth 1 -name 'sayall-rec-*.pcm' -print -quit)"
}

# Direct typing, followed by a shutdown and restart on the same socket path.
write_config type
start_daemon
run_session
cmp "$expected" "$test_dir/type.out"
stop_daemon

write_config clipboard
start_daemon
run_session
cmp "$expected" "$test_dir/clipboard.out"
stop_daemon

write_config paste
: >"$test_dir/wtype.log"
: >"$test_dir/clipboard.out"
start_daemon
run_session
cmp "$expected" "$test_dir/clipboard.out"
test "$(cat "$test_dir/wtype.log")" = '-M ctrl -k v -m ctrl'
stop_daemon

test "$(wc -l <"$test_dir/stt.log")" -eq 3
test -z "$(find "$test_dir/runtime" -maxdepth 1 -name 'sayall-rec-*.pcm' -print -quit)"
echo 'daemon E2E tests passed'
