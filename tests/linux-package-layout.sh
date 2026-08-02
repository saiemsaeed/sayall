#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo 'usage: linux-package-layout.sh <version> <binary-archive> <source-archive>' >&2
    exit 2
fi

version=$1
binary_archive=$(realpath "$2")
source_archive=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

tar -xzf "$binary_archive" -C "$work"
tar -xzf "$source_archive" -C "$work"
source_tree="$work/sayall-$version"
cp -a "$root/zig-out" "$source_tree/"
mkdir -p "$work/cargo-target/release"
cp "$root/ui/linux/target/release/sayall-hud" \
    "$work/cargo-target/release/"
cargo_home=${CARGO_HOME:-$HOME/.cargo}
test -d "$cargo_home/registry/src"
ln -s "$cargo_home" "$work/cargo-home"

validate_package() {
    local package=$1
    local tree="$work/package-$package"
    test -x "$tree/usr/bin/sayall"
    test -x "$tree/usr/bin/sayall-hud"
    test ! -e "$tree/usr/bin/sayall-process"
    test -x "$tree/usr/lib/sayall/sayall-process"
    test -f "$tree/usr/lib/systemd/user/sayall-hud.service"
    test ! -e "$tree/usr/lib/systemd/user/sayall.service"
    test -f "$tree/usr/share/applications/dev.sayall.Hud.desktop"
    test -f "$tree/usr/share/icons/hicolor/scalable/apps/dev.sayall.Hud.svg"
}

package_variant() {
    local package=$1
    local source_dir=$2
    local tree="$work/package-$package"
    mkdir -p "$tree"
    (
        # PKGBUILDs are sourced only to exercise their package() functions
        # against the exact release payload assembled above.
        source "$root/packaging/aur/$package/PKGBUILD"
        pkgver=$version
        srcdir=$source_dir
        pkgdir=$tree
        CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
        package
    )
    validate_package "$package"
}

package_variant sayall-bin "$work"
package_variant sayall "$work"
ln -s "$source_tree" "$work/sayall"
package_variant sayall-git "$work"
