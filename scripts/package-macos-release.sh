#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
    echo 'macOS artifacts must be built natively on Apple Silicon' >&2
    exit 1
fi
if [[ $(zig version) != 0.16.* ]]; then
    printf 'macOS release builds require Zig 0.16.x; found %s\n' "$(zig version)" >&2
    exit 1
fi

version=$(tr -d '[:space:]' < VERSION)
zon_version=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)
if [[ -z "$version" || "$version" != "$zon_version" ]]; then
    printf 'version mismatch: VERSION=%q build.zig.zon=%q\n' "$version" "$zon_version" >&2
    exit 1
fi

mode=${MACOS_SIGN_MODE:-adhoc}
case "$mode" in
    adhoc) identity=-; artifact_suffix=-unsigned ;;
    developer-id)
        : "${APPLE_DEVELOPER_ID_APPLICATION:?set the Developer ID Application identity}"
        : "${APPLE_TEAM_ID:?set the expected Apple signing Team ID}"
        : "${APPLE_NOTARY_KEY_PATH:?set the App Store Connect API private-key path}"
        : "${APPLE_NOTARY_KEY_ID:?set the App Store Connect key ID}"
        : "${APPLE_NOTARY_ISSUER_ID:?set the App Store Connect issuer ID}"
        identity=$APPLE_DEVELOPER_ID_APPLICATION
        artifact_suffix=
        ;;
    *) printf 'unsupported MACOS_SIGN_MODE: %s\n' "$mode" >&2; exit 1 ;;
esac

swift test --package-path ui/macos
zig build test-batch
zig build process -Doptimize=ReleaseFast -Dtarget=aarch64-macos.15.0
swift build --package-path ui/macos -c release --arch arm64
swift_bin=$(swift build --package-path ui/macos -c release --arch arm64 --show-bin-path)

app="$root/dist/macos/SayAll.app"
archive="$root/dist/sayall-$version-macos-arm64$artifact_suffix.zip"
rm -rf -- "$root/dist/macos" "$archive"
install -d "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
install -m755 "$swift_bin/SayAll" "$app/Contents/MacOS/SayAll"
install -m755 "$root/zig-out/bin/sayall-process" "$app/Contents/Helpers/sayall-process"
install -m644 ui/macos/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
[[ $("$app/Contents/Helpers/sayall-process" --version) == "sayall-process $version" ]]
"$app/Contents/Helpers/sayall-process" --stream </dev/null

for executable in "$app/Contents/MacOS/SayAll" "$app/Contents/Helpers/sayall-process"; do
    [[ $(lipo -archs "$executable") == arm64 ]] || {
        printf 'expected arm64-only executable: %s\n' "$executable" >&2
        exit 1
    }
done

if [[ "$mode" == developer-id ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp \
        "$app/Contents/Helpers/sayall-process"
    codesign --force --sign "$identity" --options runtime --timestamp \
        --entitlements ui/macos/SayAll.entitlements "$app"
else
    codesign --force --sign - "$app/Contents/Helpers/sayall-process"
    codesign --force --sign - --entitlements ui/macos/SayAll.entitlements "$app"
fi

bash scripts/verify-macos-app.sh "$app" "$version" "$mode"

mkdir -p dist
if [[ "$mode" == developer-id ]]; then
    submission="$root/dist/.sayall-$version-notarization.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
    xcrun notarytool submit "$submission" \
        --key "$APPLE_NOTARY_KEY_PATH" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" \
        --wait
    rm -f "$submission"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > SHA256SUMS.macos)
printf 'created %s\ncreated %s\n' "$archive" "$root/dist/SHA256SUMS.macos"
