# Releasing SayAll

SayAll's Zig daemon/CLI and Rust HUD share one product version. `VERSION` is
the source of truth. `build.zig.zon` and `ui/linux/Cargo.toml` must carry the
same version because their package formats require literal metadata; the
release script rejects mismatches.

Protocol versions are independent of the product version. Do not increment
the control protocol merely for an application release.

## Supported release target

Version 0.1.0 is built, tested, and supported for x86-64 Arch Linux with
Omarchy. Release binaries may work on related Wayland systems, but that is not
part of the 0.1.0 compatibility promise.

## Prepare a release

1. Start `release/<version>` from the tested `main` commit, for example
   `git switch -c release/0.1.0`. Only release branches can publish; pushes to
   `main` never create a release.
2. On the release branch, move completed entries from `Unreleased` into the
   versioned changelog section and set its date.
3. Set the same SemVer value in `VERSION`, `build.zig.zon`, and
   `ui/linux/Cargo.toml`. The branch name must match that value exactly.
4. Run `zig build test` and `cargo test --manifest-path ui/linux/Cargo.toml`.
5. Run `scripts/package-release.sh`. It checks version agreement, builds both
   executables, verifies `sayall --version`, and writes the archive and
   checksum to `dist/`.
6. Install the archive in a clean supported environment and complete a manual
   recording, transcription, HUD, typing, restart, and uninstall smoke test.
7. Commit the release preparation and push `release/<version>`. The release
   workflow repeats all checks, creates the immutable `v<version>` tag at that
   exact commit, and publishes the GitHub Release with its archive and
   checksum.
8. After publication, merge the release branch back into `main` so version and
   changelog history remain authoritative. This merge runs CI but cannot
   publish another release. The release branch may then be deleted.

Do not move or recreate a published tag. Corrections receive a new patch
release. Enable **immutable releases** in the GitHub repository settings before
publishing the first tag; the workflow also refuses to overwrite existing
assets.

Treat a successfully published release branch as frozen. If publication
succeeds and a defect is found afterward, prepare a new patch version rather
than pushing replacement artifacts to the same branch.

## Publish the AUR packages

Publish AUR updates only after the GitHub Release and its checksum are final:

1. In `packaging/aur/sayall-bin`, set `pkgver` to the release, reset `pkgrel`
   to 1, and replace the archive checksum with the checksum from the published
   `SHA256SUMS`.
2. In `packaging/aur/sayall`, set `pkgver` to the release, reset `pkgrel` to 1,
   and update the source archive checksum. Keep the pinned `websocket.zig`
   source unchanged unless the application dependency changed.
3. Run a clean `makepkg` build in both stable package directories. Verify the
   packaged CLI reports the release version and both systemd units use
   `/usr/bin`.
4. Run a clean `makepkg` build for `sayall-git`. Its `pkgver()` function
   derives the development version from Git and does not require an update for
   every upstream commit.
5. Regenerate every `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`, then
   copy each package directory into its corresponding standalone AUR Git
   repository and push it.
6. Upgrade from the previous `sayall-bin`, run
   `systemctl --user restart sayall.service sayall-hud.service`, then run
   `sayall doctor` and complete a recording, transcription, HUD, and typing
   smoke test. Repeat the explicit restart after switching between all three
   mutually conflicting package variants, and verify each switch preserves
   `~/.config/sayall/config.json`.
7. Confirm the public pages for `sayall-bin`, `sayall`, and `sayall-git` show
   the intended versions and maintainer.

## Service paths in packages

The checked-in systemd units intentionally target `%h/.local/bin` for the
documented manual installation. Distribution packages must install equivalent
units whose `ExecStart` paths use that package manager's installation prefix;
they must not patch users' existing units during upgrades.
