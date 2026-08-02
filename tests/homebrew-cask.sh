#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp); trap 'rm -f "$output"' EXIT
bash "$root/scripts/generate-homebrew-cask.sh" 1.2.3 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$output"
ruby -c "$output" | grep -Fq 'Syntax OK'
grep -Fq 'version "1.2.3"' "$output"
grep -Fq 'sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$output"
grep -Fq 'releases/download/v#{version}/sayall-#{version}-macos-arm64.dmg' "$output"
grep -Fq 'binary "#{appdir}/SayAll.app/Contents/Helpers/sayall"' "$output"
grep -Fq 'depends_on arch: :arm64' "$output"
grep -Fq 'depends_on macos: ">= :sequoia"' "$output"
grep -Fq 'uninstall quit: "pro.leets.sayall"' "$output"
grep -Fq '"~/.config/sayall"' "$output"
! grep -Fq 'delete:' "$output"
! grep -Fq ':no_check' "$output"

# Homebrew's binary stanza and the menu installer must both resolve to the
# bundled public CLI, without either claiming or deleting user configuration.
grep -Fq 'Contents/Helpers/sayall' "$root/ui/macos/Sources/SayAll/App.swift"
grep -Fq 'destinationOfSymbolicLink' "$root/ui/macos/Sources/SayAll/App.swift"
grep -Fq 'already exists and was not changed' "$root/ui/macos/Sources/SayAll/App.swift"
grep -Fq 'Remove Command Line Tool…' "$root/ui/macos/Sources/SayAll/App.swift"
