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

[[ -d "$app" && -x "$main" && -x "$helper" && -f "$plist" ]]
[[ $(lipo -archs "$main") == arm64 ]]
[[ $(lipo -archs "$helper") == arm64 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == pro.leets.sayall ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist") == 15.0 ]]
grep -Eq 'minos 15\.0' <(vtool -show-build "$main")
grep -Eq 'minos 15\.0' <(vtool -show-build "$helper")
codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$mode" == developer-id ]]; then
    details=$(codesign --display --verbose=4 "$app" 2>&1)
    grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$details"
    grep -Eq 'flags=.*runtime' <<<"$details"
elif [[ "$mode" != adhoc ]]; then
    printf 'unsupported signing mode: %s\n' "$mode" >&2
    exit 2
fi
