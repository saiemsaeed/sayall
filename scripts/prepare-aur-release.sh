#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo 'usage: prepare-aur-release.sh <version> <binary-sha256> <source-sha256> <output-directory>' >&2
    exit 2
fi

version=$1
binary_sha=$2
source_sha=$3
output=$4
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ! $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'invalid release version: %q\n' "$version" >&2
    exit 1
fi
for checksum in "$binary_sha" "$source_sha"; do
    if [[ ! $checksum =~ ^[0-9a-f]{64}$ ]]; then
        printf 'invalid SHA-256 checksum: %q\n' "$checksum" >&2
        exit 1
    fi
done
if [[ -e $output ]]; then
    printf 'output path already exists: %s\n' "$output" >&2
    exit 1
fi

mkdir -p "$output"
cp -a "$root/packaging/aur/." "$output/"

bin_pkgbuild="$output/sayall/PKGBUILD"
source_pkgbuild="$output/sayall-src/PKGBUILD"
dependency_sha=$(sed -n "/^sha256sums=(/,/^)/ s/^  '\([0-9a-f]\{64\}\)'$/\1/p" \
    "$source_pkgbuild" | sed -n '2p')
if [[ -z $dependency_sha ]]; then
    echo 'could not read the pinned source dependency checksum' >&2
    exit 1
fi

sed -i \
    -e "s/^pkgver=.*/pkgver=$version/" \
    -e 's/^pkgrel=.*/pkgrel=1/' \
    -e "s/^sha256sums=('[0-9a-f]\{64\}')$/sha256sums=('$binary_sha')/" \
    "$bin_pkgbuild"

sed -i \
    -e "s/^pkgver=.*/pkgver=$version/" \
    -e 's/^pkgrel=.*/pkgrel=1/' \
    -e 's|$url/archive/refs/tags/v$pkgver.tar.gz|$url/releases/download/v$pkgver/sayall-$pkgver.tar.gz|' \
    -e "0,/^  '[0-9a-f]\{64\}'$/s//  '$source_sha'/" \
    "$source_pkgbuild"

grep -Fqx "pkgver=$version" "$bin_pkgbuild"
grep -Fqx "sha256sums=('$binary_sha')" "$bin_pkgbuild"
grep -Fqx "pkgver=$version" "$source_pkgbuild"
grep -Fq '$url/releases/download/v$pkgver/sayall-$pkgver.tar.gz' "$source_pkgbuild"
mapfile -t source_checksums < <(
    sed -n "/^sha256sums=(/,/^)/ s/^  '\([0-9a-f]\{64\}\)'$/\1/p" "$source_pkgbuild"
)
if [[ ${#source_checksums[@]} -ne 2 || \
      ${source_checksums[0]} != "$source_sha" || \
      ${source_checksums[1]} != "$dependency_sha" ]]; then
    echo 'source checksums are not in the expected order' >&2
    exit 1
fi

for package in sayall-src sayall sayall-git; do
    (
        cd "$output/$package"
        makepkg --printsrcinfo > .SRCINFO
    )
done
