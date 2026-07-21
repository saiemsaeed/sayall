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
   exact commit, and publishes the GitHub Release with binary and source
   archives plus their checksums. A separate default-branch workflow then
   publishes all three AUR repositories from those immutable assets.
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

## Automated AUR publishing

The default-branch `Publish AUR` workflow runs only after the `Release` workflow
succeeds and verifies that the published release targets the triggering commit.
It uses a dedicated, unencrypted CI key stored in the `AUR_SSH_PRIVATE_KEY`
GitHub Actions secret. Its public-key fingerprint is stored in the
`AUR_SSH_KEY_FINGERPRINT` Actions variable and checked before any AUR access.
Add only that key's public half to the maintainer's AUR account; do not reuse a
personal or 1Password-managed SSH key. The workflow pins the AUR ED25519 host
key rather than trusting a dynamic `ssh-keyscan` result. Keeping the publishing
workflow on the default branch prevents release-branch workflow changes from
reading the AUR credential.

`scripts/prepare-aur-release.sh` copies the checked-in package templates,
updates both stable package versions and final checksums, and regenerates all
three `.SRCINFO` files. The workflow then clones and pushes each standalone AUR
repository. A retry is safe: packages that already match are skipped.

Before pushing the release branch:

1. Run a clean `makepkg` build in both stable package directories. Verify the
   packaged CLI reports the release version and both systemd units use
   `/usr/bin`.
2. Run a clean `makepkg` build for `sayall-git`. Its `pkgver()` function
   derives the development version from Git and does not require an update for
   every upstream commit.
3. Upgrade from the previous `sayall-bin`, run `sayall setup`, then run
   `sayall doctor` and complete a recording, transcription, HUD, and typing
   smoke test. Repeat `sayall setup` after switching between all three mutually
   conflicting package variants, and verify each switch preserves
   `~/.config/sayall/config.json`. Verify `sayall update` detects and targets
   the installed variant before preparing the next release.
4. After the workflow succeeds, confirm the public pages for `sayall-bin`,
   `sayall`, and `sayall-git` show
   the intended versions and maintainer.

## Service paths in packages

The checked-in systemd units intentionally target `%h/.local/bin` for the
documented manual installation. Distribution packages must install equivalent
units whose `ExecStart` paths use that package manager's installation prefix;
they must not patch users' existing units during upgrades.
