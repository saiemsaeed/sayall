#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    echo 'usage: linux-installed-artifact-smoke.sh <version> <binary-archive>' >&2
    exit 2
fi

version=$1
archive=$(realpath "$2")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
payload="$work/payload"
home="$work/home"
runtime="$work/runtime"
mkdir -m700 "$payload" "$home" "$runtime"

# The archive is data under test. Only this trusted checkout harness performs
# extraction and installation; nothing from the payload is sourced as a script.
tar -xzf "$archive" -C "$payload"
source="$payload/sayall-$version-linux-x86_64"
[[ -d "$source" ]]

# Mirror the README's per-user archive installation in a disposable HOME.
install -Dm755 -t "$home/.local/bin" "$source/bin/sayall" "$source/bin/sayall-hud"
install -Dm755 "$source/lib/sayall/sayall-process" \
    "$home/.local/lib/sayall/sayall-process"
install -Dm644 -t "$home/.config/systemd/user" "$source"/share/systemd/user/*.service
install -Dm644 -t "$home/.local/share/applications" "$source"/share/applications/*.desktop
install -Dm644 -t "$home/.local/share/icons/hicolor/scalable/apps" \
    "$source"/share/icons/hicolor/scalable/apps/*.svg

mode() { stat -c '%a' "$1"; }
owner() { stat -c '%u:%g' "$1"; }
expected_owner=$(id -u):$(id -g)
for executable in "$home/.local/bin/sayall" "$home/.local/bin/sayall-hud" \
    "$home/.local/lib/sayall/sayall-process"; do
    [[ -x "$executable" && $(mode "$executable") == 755 ]]
    [[ $(owner "$executable") == "$expected_owner" ]]
done
for data in "$home/.config/systemd/user/sayall-hud.service" \
    "$home/.local/share/applications/dev.sayall.Hud.desktop" \
    "$home/.local/share/icons/hicolor/scalable/apps/dev.sayall.Hud.svg"; do
    [[ -f "$data" && $(mode "$data") == 644 ]]
    [[ $(owner "$data") == "$expected_owner" ]]
done

export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$runtime"
export PATH="$home/.local/bin:/usr/bin:/bin"
[[ $(sayall --version) == "sayall $version" ]]
[[ $(sayall-hud --version) == "sayall-hud $version" ]]
worker="$home/.local/lib/sayall/sayall-process"
[[ $("$worker" --version) == "sayall-process $version" ]]
! command -v sayall-process >/dev/null 2>&1

info=$("$worker" --worker-info)
grep -Fq '"protocol_version":1' <<<"$info"
grep -Fq "\"build_version\":\"$version\"" <<<"$info"
bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/worker-info-wait.sh" "$worker"

service="$home/.config/systemd/user/sayall-hud.service"
grep -Fxq 'ExecStart=%h/.local/bin/sayall-hud --autostart' "$service"
[[ -x "$home/.local/bin/sayall-hud" ]]
desktop="$home/.local/share/applications/dev.sayall.Hud.desktop"
grep -Fxq 'Exec=sayall-hud' "$desktop"
grep -Fxq 'Icon=dev.sayall.Hud' "$desktop"
[[ -x "$home/.local/bin/$(sed -n 's/^Exec=//p' "$desktop")" ]]
icon=$(sed -n 's/^Icon=//p' "$desktop")
[[ -f "$home/.local/share/icons/hicolor/scalable/apps/$icon.svg" ]]

# Public config commands require neither a graphical session nor hardware.
sayall config init >/dev/null
config="$home/.config/sayall/config.json"
[[ -f "$config" && $(mode "$home/.config/sayall") == 700 && $(mode "$config") == 600 ]]
[[ $(owner "$home/.config/sayall") == "$expected_owner" ]]
[[ $(owner "$config") == "$expected_owner" ]]
sayall config validate >/dev/null
checksum=$(sha256sum "$config")
! sayall config init >/dev/null 2>&1
[[ $(sha256sum "$config") == "$checksum" ]]
[[ $(mode "$runtime") == 700 ]]

# Model default manual uninstall without contacting a real user manager. Remove
# every installed payload file, while retaining user-owned configuration.
rm -f -- "$home/.local/bin/sayall" "$home/.local/bin/sayall-hud" \
    "$home/.local/lib/sayall/sayall-process" \
    "$home/.config/systemd/user/sayall-hud.service" \
    "$home/.local/share/applications/dev.sayall.Hud.desktop" \
    "$home/.local/share/icons/hicolor/scalable/apps/dev.sayall.Hud.svg"
! find "$home/.local" "$home/.config/systemd" -type f -print -quit | grep -q .
[[ -f "$config" && $(mode "$config") == 600 ]]
