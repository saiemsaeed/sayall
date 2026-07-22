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

if [[ -z "$version" || "$version" != "$zon_version" || "$version" != "$cargo_version" ]]; then
    printf 'version mismatch: VERSION=%q build.zig.zon=%q Cargo.toml=%q\n' \
        "$version" "$zon_version" "$cargo_version" >&2
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
cargo build --locked --release --manifest-path ui/linux/Cargo.toml

reported_version=$(zig-out/bin/sayall --version)
if [[ "$reported_version" != "sayall $version" ]]; then
    printf 'unexpected version output: %q\n' "$reported_version" >&2
    exit 1
fi

source_name="sayall-$version"
name="$source_name-linux-x86_64"
stage="dist/$name"
rm -rf -- "$stage"
mkdir -p \
    "$stage/bin" \
    "$stage/share/doc/sayall" \
    "$stage/share/licenses/sayall" \
    "$stage/share/systemd/user"
install -m755 zig-out/bin/sayall ui/linux/target/release/sayall-hud "$stage/bin/"
install -m644 README.md CHANGELOG.md "$stage/share/doc/sayall/"
install -m644 LICENSE licenses/websocket.zig-LICENSE "$stage/share/licenses/sayall/"
python3 scripts/third-party-licenses.py \
    "$stage/share/licenses/sayall/RUST-THIRD-PARTY-LICENSES.txt"
install -m644 sayall.service sayall-hud.service "$stage/share/systemd/user/"

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
    src
    ui
    sayall.service
    sayall-hud.service
    README.md
    docs
)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --exclude='ui/linux/target' --transform="s|^|$source_name/|" \
    -C "$root" -czf "$source_archive" "${source_paths[@]}"
(cd dist && sha256sum "${name}.tar.gz" "${source_name}.tar.gz" > SHA256SUMS)

printf 'created %s\ncreated %s\ncreated dist/SHA256SUMS\n' \
    "$archive" "$source_archive"
