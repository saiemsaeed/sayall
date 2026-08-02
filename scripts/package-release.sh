#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

version=$(tr -d '[:space:]' < VERSION)
zon_version=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)
cargo_version=$(awk '
    /^\[package\]$/ { package = 1; next }
    /^\[/ { package = 0 }
    package && /^version = "/ { gsub(/^version = "|"$/, ""); print; exit }
' ui/linux/Cargo.toml)
cargo_lock_version=$(awk '
    /^\[\[package\]\]$/ { package = 1; hud = 0; next }
    /^\[/ { package = 0; hud = 0 }
    package && /^name = "sayall-hud"$/ { hud = 1; next }
    package && hud && /^version = "/ {
        gsub(/^version = "|"$/, ""); print; exit
    }
' ui/linux/Cargo.lock)

if [[ -z "$version" || "$version" != "$zon_version" || \
      "$version" != "$cargo_version" || "$version" != "$cargo_lock_version" ]]; then
    printf 'version mismatch: VERSION=%q build.zig.zon=%q Cargo.toml=%q Cargo.lock=%q\n' \
        "$version" "$zon_version" "$cargo_version" "$cargo_lock_version" >&2
    exit 1
fi

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'release artifacts are currently supported only on x86-64 Linux' >&2
    exit 1
fi

if [[ $(zig version) != 0.16.* ]]; then
    printf 'release builds require Zig 0.16.x; found %s\n' "$(zig version)" >&2
    exit 1
fi

zig build test
cargo test --locked --manifest-path ui/linux/Cargo.toml
zig build -Doptimize=ReleaseFast
zig build process -Doptimize=ReleaseFast
cargo build --locked --release --manifest-path ui/linux/Cargo.toml

reported_version=$(zig-out/bin/sayall --version)
if [[ "$reported_version" != "sayall $version" ]]; then
    printf 'unexpected version output: %q\n' "$reported_version" >&2
    exit 1
fi
if [[ $(zig-out/bin/sayall-process --version) != "sayall-process $version" ]]; then
    echo 'private worker version does not match the release' >&2
    exit 1
fi
if [[ $(ui/linux/target/release/sayall-hud --version) != "sayall-hud $version" ]]; then
    echo 'Linux application version does not match the release' >&2
    exit 1
fi

source_name="sayall-$version"
name="$source_name-linux-x86_64"
stage="dist/$name"
rm -rf -- "$stage"
mkdir -p \
    "$stage/bin" \
    "$stage/lib/sayall" \
    "$stage/share/doc/sayall" \
    "$stage/share/applications" \
    "$stage/share/icons/hicolor/scalable/apps" \
    "$stage/share/licenses/sayall" \
    "$stage/share/systemd/user"
install -m755 zig-out/bin/sayall ui/linux/target/release/sayall-hud "$stage/bin/"
install -m755 zig-out/bin/sayall-process "$stage/lib/sayall/sayall-process"
install -m644 ui/linux/dev.sayall.Hud.desktop "$stage/share/applications/"
install -m644 ui/linux/dev.sayall.Hud.svg \
    "$stage/share/icons/hicolor/scalable/apps/"
install -m644 README.md CHANGELOG.md "$stage/share/doc/sayall/"
install -m644 LICENSE licenses/websocket.zig-LICENSE "$stage/share/licenses/sayall/"
python3 scripts/third-party-licenses.py \
    "$stage/share/licenses/sayall/RUST-THIRD-PARTY-LICENSES.txt"
install -m644 sayall-hud.service "$stage/share/systemd/user/"
sed -i 's|ExecStart=/usr/bin/|ExecStart=%h/.local/bin/|' \
    "$stage/share/systemd/user/sayall-hud.service"
grep -Fxq 'ExecStart=%h/.local/bin/sayall-hud --autostart' \
    "$stage/share/systemd/user/sayall-hud.service"
test ! -e "$stage/bin/sayall-process"
grep -Fxq 'Exec=sayall-hud' "$stage/share/applications/dev.sayall.Hud.desktop"
grep -Fxq 'Icon=dev.sayall.Hud' "$stage/share/applications/dev.sayall.Hud.desktop"
grep -Fq '<svg ' "$stage/share/icons/hicolor/scalable/apps/dev.sayall.Hud.svg"

archive="dist/$name.tar.gz"
source_archive="dist/$source_name.tar.gz"
epoch=${SOURCE_DATE_EPOCH:-0}
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -C dist -czf "$archive" "$name"
source_paths=(
    build.zig
    build.zig.zon
    VERSION
    LICENSE
    CHANGELOG.md
    licenses
    scripts
    tests
    daemon
    ui
    sayall-hud.service
    README.md
    docs
)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --exclude='ui/linux/target' --exclude='ui/macos/.build' \
    --transform="s|^|$source_name/|" \
    -C "$root" -czf "$source_archive" "${source_paths[@]}"
(cd dist && sha256sum "${name}.tar.gz" "${source_name}.tar.gz" > SHA256SUMS)
bash tests/linux-package-layout.sh "$version" "$archive" "$source_archive"

printf 'created %s\ncreated %s\ncreated dist/SHA256SUMS\n' \
    "$archive" "$source_archive"
