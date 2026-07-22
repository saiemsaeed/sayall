#!/bin/sh
set -eu

sayall=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d /tmp/sayall-shortcut-test.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM

mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/config/hypr"
cp "$script_dir/fixtures/systemctl" "$test_dir/bin/systemctl"
cp "$script_dir/fixtures/hyprctl" "$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/systemctl"
chmod +x "$test_dir/bin/hyprctl"

root=$test_dir/config/hypr/hyprland.conf
bindings=$test_dir/config/hypr/bindings.conf
systemctl_log=$test_dir/systemctl.log
output=$test_dir/output

printf '%s\n' 'source = bindings.conf' >"$root"
printf '%s\n' 'bind = CTRL, SLASH, exec, sayall toggle' >"$bindings"
cp "$root" "$test_dir/root.before"
cp "$bindings" "$test_dir/bindings.before"

SAYALL_TEST_SYSTEMCTL_LOG=$systemctl_log \
HOME=$test_dir/home \
XDG_CONFIG_HOME=$test_dir/config \
PATH=$test_dir/bin:$PATH \
env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" setup >"$output" 2>&1

cmp "$test_dir/root.before" "$root"
cmp "$test_dir/bindings.before" "$bindings"
test ! -e "$test_dir/config/hypr/sayall.conf"
test ! -e "$test_dir/config/sayall/shortcut.json"
grep -q 'leaving the existing binding unchanged' "$output"
test "$(wc -l <"$systemctl_log")" -eq 3

variable_config=$test_dir/variable-config
mkdir -p "$variable_config/hypr"
cp "$script_dir/fixtures/hypr-variable-binding.conf" "$variable_config/hypr/hyprland.conf"
cp "$variable_config/hypr/hyprland.conf" "$test_dir/variable-binding.before"
if HOME=$test_dir/home XDG_CONFIG_HOME=$variable_config \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut set SUPER+H >"$output" 2>&1; then
  echo 'variable-based modifier unexpectedly passed conflict scanning' >&2
  exit 1
fi
grep -q 'unresolved Hyprland expression' "$output"
grep -q 'No files were changed' "$output"
cmp "$test_dir/variable-binding.before" "$variable_config/hypr/hyprland.conf"
test ! -e "$variable_config/hypr/sayall.conf"
test ! -e "$variable_config/sayall/shortcut.json"

variable_source_config=$test_dir/variable-source-config
mkdir -p "$variable_source_config/hypr"
cp "$script_dir/fixtures/hypr-variable-source.conf" "$variable_source_config/hypr/hyprland.conf"
cp "$variable_source_config/hypr/hyprland.conf" "$test_dir/variable-source.before"
if HOME=$test_dir/home XDG_CONFIG_HOME=$variable_source_config \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut reset >"$output" 2>&1; then
  echo 'variable-based source unexpectedly passed conflict scanning' >&2
  exit 1
fi
grep -q 'unresolved Hyprland expression' "$output"
grep -q 'No files were changed' "$output"
cmp "$test_dir/variable-source.before" "$variable_source_config/hypr/hyprland.conf"
test ! -e "$variable_source_config/hypr/sayall.conf"
test ! -e "$variable_source_config/sayall/shortcut.json"

symlink_config=$test_dir/symlink-config
mkdir -p "$symlink_config/hypr"
symlink_target=$test_dir/symlink-target.conf
printf '%s\n' '# symlink target must survive' >"$symlink_target"
cp "$symlink_target" "$test_dir/symlink-target.before"
ln -s "$symlink_target" "$symlink_config/hypr/hyprland.conf"
symlink_before=$(readlink "$symlink_config/hypr/hyprland.conf")
if HOME=$test_dir/home XDG_CONFIG_HOME=$symlink_config \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut reset >"$output" 2>&1; then
  echo 'symlinked hyprland.conf unexpectedly accepted' >&2
  exit 1
fi
grep -q 'symlinked Hyprland roots are unsupported' "$output"
grep -q 'No files were changed' "$output"
test -L "$symlink_config/hypr/hyprland.conf"
test "$(readlink "$symlink_config/hypr/hyprland.conf")" = "$symlink_before"
cmp "$test_dir/symlink-target.before" "$symlink_target"
test ! -e "$symlink_config/sayall"
test ! -e "$symlink_config/sayall/shortcut.lock"
test ! -e "$symlink_config/hypr/sayall.conf"
test ! -e "$symlink_config/sayall/shortcut.json"

if HOME=$test_dir/home XDG_CONFIG_HOME=$test_dir/config \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut set SUPER+H >"$output" 2>&1; then
  echo 'shortcut set unexpectedly took ownership from a manual binding' >&2
  exit 1
fi
grep -q 'owned by an existing manual Hyprland binding' "$output"
if HOME=$test_dir/home XDG_CONFIG_HOME=$test_dir/config \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut disable >"$output" 2>&1; then
  echo 'shortcut disable unexpectedly ignored a manual binding' >&2
  exit 1
fi
grep -q 'owned by an existing manual Hyprland binding' "$output"
HOME=$test_dir/home XDG_CONFIG_HOME=$test_dir/config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut reset >"$output" 2>&1
cmp "$test_dir/root.before" "$root"
cmp "$test_dir/bindings.before" "$bindings"
test ! -e "$test_dir/config/hypr/sayall.conf"
test ! -e "$test_dir/config/sayall/shortcut.json"

managed_config=$test_dir/managed-config
managed_root=$managed_config/hypr/hyprland.conf
mkdir -p "$managed_config/hypr"
printf '%s\n' '# isolated managed shortcut test' >"$managed_root"

HOME=$test_dir/home XDG_CONFIG_HOME=$managed_config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut show >"$output" 2>&1
grep -q 'CTRL+SLASH (default' "$output"

HOME=$test_dir/home XDG_CONFIG_HOME=$managed_config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut set SUPER+H >"$output" 2>&1
cp "$managed_root" "$test_dir/managed-root.before"
cp "$managed_config/hypr/sayall.conf" "$test_dir/managed-fragment.before"
cp "$managed_config/sayall/shortcut.json" "$test_dir/managed-state.before"
HOME=$test_dir/home XDG_CONFIG_HOME=$managed_config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut set SUPER+H >"$output" 2>&1
cmp "$test_dir/managed-root.before" "$managed_root"
cmp "$test_dir/managed-fragment.before" "$managed_config/hypr/sayall.conf"
cmp "$test_dir/managed-state.before" "$managed_config/sayall/shortcut.json"
test "$(grep -c 'BEGIN SAYALL MANAGED SHORTCUT' "$managed_root")" -eq 1
grep -q 'bindd = SUPER, H, Toggle SayAll dictation, exec, sayall toggle' \
  "$managed_config/hypr/sayall.conf"

: >"$systemctl_log"
SAYALL_TEST_SYSTEMCTL_LOG=$systemctl_log \
HOME=$test_dir/home \
XDG_CONFIG_HOME=$managed_config \
PATH=$test_dir/bin:$PATH \
env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" setup >"$output" 2>&1
grep -q '"shortcut": "SUPER+H"' "$managed_config/sayall/shortcut.json"
test "$(wc -l <"$systemctl_log")" -eq 3

HOME=$test_dir/home XDG_CONFIG_HOME=$managed_config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut disable >"$output" 2>&1
! grep -q '^bind' "$managed_config/hypr/sayall.conf"
HOME=$test_dir/home XDG_CONFIG_HOME=$managed_config \
  env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" shortcut reset >"$output" 2>&1
grep -q 'bindd = CTRL, SLASH, Toggle SayAll dictation, exec, sayall toggle' \
  "$managed_config/hypr/sayall.conf"

hyprctl_log=$test_dir/hyprctl.log
SAYALL_TEST_HYPRCTL_LOG=$hyprctl_log \
HOME=$test_dir/home \
XDG_CONFIG_HOME=$managed_config \
PATH=$test_dir/bin:$PATH \
HYPRLAND_INSTANCE_SIGNATURE=test-instance \
"$sayall" shortcut set ALT+F10 >"$output" 2>&1
test "$(wc -l <"$hyprctl_log")" -eq 2
grep -q 'bindd = ALT, F10, Toggle SayAll dictation, exec, sayall toggle' \
  "$managed_config/hypr/sayall.conf"

cp "$managed_root" "$test_dir/reload-root.before"
cp "$managed_config/hypr/sayall.conf" "$test_dir/reload-fragment.before"
cp "$managed_config/sayall/shortcut.json" "$test_dir/reload-state.before"
: >"$hyprctl_log"
if SAYALL_TEST_HYPRCTL_LOG=$hyprctl_log \
    SAYALL_TEST_CONFIGERRORS='test config error' \
    HOME=$test_dir/home \
    XDG_CONFIG_HOME=$managed_config \
    PATH=$test_dir/bin:$PATH \
    HYPRLAND_INSTANCE_SIGNATURE=test-instance \
    "$sayall" shortcut set CTRL+ALT+Q >"$output" 2>&1; then
  echo 'shortcut change unexpectedly survived Hyprland config errors' >&2
  exit 1
fi
cmp "$test_dir/reload-root.before" "$managed_root"
cmp "$test_dir/reload-fragment.before" "$managed_config/hypr/sayall.conf"
cmp "$test_dir/reload-state.before" "$managed_config/sayall/shortcut.json"
grep -q 'previous shortcut files were restored' "$output"
test "$(wc -l <"$hyprctl_log")" -eq 4

printf '%s\n' 'bind = CTRL, SLASH, exec, other-command' >"$bindings"
: >"$systemctl_log"
if SAYALL_TEST_SYSTEMCTL_LOG=$systemctl_log \
    HOME=$test_dir/home \
    XDG_CONFIG_HOME=$test_dir/config \
    PATH=$test_dir/bin:$PATH \
    env -u HYPRLAND_INSTANCE_SIGNATURE "$sayall" setup >"$output" 2>&1; then
  echo 'setup unexpectedly accepted a conflicting shortcut' >&2
  exit 1
fi

grep -q 'shortcut conflicts with' "$output"
grep -q 'services were enabled and restarted' "$output"
test "$(wc -l <"$systemctl_log")" -eq 3
test ! -e "$test_dir/config/hypr/sayall.conf"
test ! -e "$test_dir/config/sayall/shortcut.json"

cp "$managed_config/hypr/sayall.conf" "$test_dir/concurrent-fragment.before"
cp "$managed_config/sayall/shortcut.json" "$test_dir/concurrent-state.before"
: >"$hyprctl_log"
if SAYALL_TEST_HYPRCTL_LOG=$hyprctl_log \
    SAYALL_TEST_CONFIGERRORS='test config error' \
    SAYALL_TEST_MUTATE_ROOT_ON_RELOAD=$managed_root \
    HOME=$test_dir/home \
    XDG_CONFIG_HOME=$managed_config \
    PATH=$test_dir/bin:$PATH \
    HYPRLAND_INSTANCE_SIGNATURE=test-instance \
    "$sayall" shortcut set SUPER+F12 >"$output" 2>&1; then
  echo 'concurrent rollback modification unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'could not safely restore every transaction file' "$output"
! grep -q 'previous shortcut files were restored' "$output"
grep -q '^# concurrent external edit$' "$managed_root"
cmp "$test_dir/concurrent-fragment.before" "$managed_config/hypr/sayall.conf"
cmp "$test_dir/concurrent-state.before" "$managed_config/sayall/shortcut.json"
