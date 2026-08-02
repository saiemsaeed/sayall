#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
    echo 'usage: generate-homebrew-cask.sh <version> <dmg-sha256> <output>' >&2
    exit 2
fi
version=$1
sha256=$2
output=$3
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
[[ $sha256 =~ ^[0-9a-f]{64}$ ]]
mkdir -p "$(dirname "$output")"
cat > "$output" <<EOF
cask "sayall" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/saiemsaeed/sayall/releases/download/v#{version}/sayall-#{version}-macos-arm64.dmg"
  name "SayAll"
  desc "Voice dictation for Apple Silicon Macs"
  homepage "https://github.com/saiemsaeed/sayall"

  livecheck do
    skip "The release workflow updates this Cask from immutable assets"
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "SayAll.app"
  binary "#{appdir}/SayAll.app/Contents/Helpers/sayall"

  uninstall quit: "pro.leets.sayall"

  zap trash: [
    "~/.config/sayall",
    "~/Library/Application Support/SayAll",
  ]
end
EOF
