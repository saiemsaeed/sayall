#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
    echo 'usage: verify-macos-dmg.sh <dmg> <version> <adhoc|developer-id>' >&2
    exit 2
fi

dmg=$1
version=$2
mode=$3
mount=$(mktemp -d)
attached=false
cleanup() {
    if $attached; then hdiutil detach -quiet "$mount"; fi
    rmdir "$mount"
}
trap cleanup EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
attached=true
[[ -d "$mount/SayAll.app" ]]
[[ -L "$mount/Applications" ]]
[[ $(readlink "$mount/Applications") == /Applications ]]
codesign --verify --strict --verbose=2 "$dmg"
bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/verify-macos-app.sh" \
    "$mount/SayAll.app" "$version" "$mode"
if [[ "$mode" == developer-id ]]; then
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature \
        --verbose=2 "$dmg"
fi
