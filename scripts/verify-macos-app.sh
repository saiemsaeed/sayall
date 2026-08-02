#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
    echo 'usage: verify-macos-app.sh <SayAll.app> <version> <adhoc|developer-id>' >&2
    exit 2
fi

app=$1
version=$2
mode=$3
plist="$app/Contents/Info.plist"
main="$app/Contents/MacOS/SayAll"
helper="$app/Contents/Helpers/sayall-process"
cli="$app/Contents/Helpers/sayall"

[[ -d "$app" && -x "$main" && -x "$cli" && -x "$helper" && -f "$plist" ]]
[[ $(lipo -archs "$main") == arm64 ]]
[[ $(lipo -archs "$cli") == arm64 ]]
[[ $(lipo -archs "$helper") == arm64 ]]
[[ $("$cli" --version) == "sayall $version" ]]
[[ $("$helper" --version) == "sayall-process $version" ]]
help=$("$cli" --help)
grep -Fq 'sayall status' <<<"$help"
grep -Fq 'sayall config init' <<<"$help"
! grep -Eq 'sayall (daemon|service|setup|restart|start|stop|update)' <<<"$help"
xdg=$(mktemp -d); trap 'rm -rf "$xdg"' EXIT
XDG_CONFIG_HOME="$xdg" HOME=/definitely/poisoned "$cli" config init >/dev/null
[[ $(stat -f '%Lp' "$xdg/sayall") == 700 ]]
[[ $(stat -f '%Lp' "$xdg/sayall/config.json") == 600 ]]
! XDG_CONFIG_HOME="$xdg" HOME=/definitely/poisoned "$cli" config init >/dev/null 2>&1
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == pro.leets.sayall ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist") == 15.0 ]]
grep -Eq 'minos 15\.0' <(vtool -show-build "$main")
grep -Eq 'minos 15\.0' <(vtool -show-build "$cli")
grep -Eq 'minos 15\.0' <(vtool -show-build "$helper")
codesign --verify --strict --verbose=2 "$cli"
codesign --verify --strict --verbose=2 "$helper"
codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$mode" == developer-id ]]; then
    details=$(codesign --display --verbose=4 "$app" 2>&1)
    grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$details"
    grep -Eq 'flags=.*runtime' <<<"$details"
    for executable in "$cli" "$helper"; do
        details=$(codesign --display --verbose=4 "$executable" 2>&1)
        grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$details"
        grep -Eq 'flags=.*runtime' <<<"$details"
    done
elif [[ "$mode" != adhoc ]]; then
    printf 'unsupported signing mode: %s\n' "$mode" >&2
    exit 2
fi
