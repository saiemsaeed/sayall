# Releasing SayAll

SayAll's Zig daemon/CLI and Rust HUD share one product version. `VERSION` is
the source of truth. `build.zig.zon` and `ui/linux/Cargo.toml` must carry the
same version because their package formats require literal metadata, and
`ui/linux/Cargo.lock` records that local HUD package version. The release
script rejects a mismatch among all four files.

Protocol versions are independent of the product version. Do not increment
the control protocol merely for an application release.

## Supported release targets and publication gates

| Platform / target | Release status |
| --- | --- |
| x86-64 Arch Linux with Omarchy (Wayland/Hyprland) | Supported and tested; Linux archive and AUR packages |
| Apple Silicon arm64, macOS 15.0+ | Native ZIP product implemented; publication requires external signing/notarization and completed physical qualification |
| Windows (`x86_64-windows` compile target) | Core compile readiness only; no app, runtime, package, or installable output |

Release binaries may work on related Linux Wayland systems, but that is not
part of the compatibility promise. The Darwin core check is distinct from the
native macOS app build. The Windows check is not a release artifact. See the
accepted [0.1.6 macOS ADR](adr-macos-0.1.6.md), the
[macOS qualification gate](macos-release-qualification.md), and the Linux-only
HUD/control [`protocol-v1 compatibility contract`](protocol-v1.md).

## macOS release credentials and qualification

Normal CI runs on macOS 15 arm64, tests, and ad-hoc assembles a clearly named
`-unsigned` ZIP without release credentials. That artifact is evidence of
automated readiness only and must not be published as the supported download.

`scripts/package-macos-release.sh` builds with a macOS 15 deployment target and
produces the tested, ad-hoc-signed CI candidate. The protected Release workflow
downloads that exact candidate, then—without running repository build or test
code while credentials are present—signs the nested helper and app with
Developer ID and Hardened Runtime, notarizes, staples, verifies, and emits
`sayall-VERSION-macos-arm64.zip` plus `SHA256SUMS.macos`. A second protected
promotion gate binds the approved SHA-256 before combining macOS, Linux, and
source entries into one published `SHA256SUMS`.

The protected GitHub environment is `macos-release`. Configure variables:

- `APPLE_TEAM_ID`
- `MACOS_016_QUALIFIED` (set only after the physical 0.1.6 gate is approved)
- `MACOS_016_APPROVED_SHA256` (the exact signed candidate approved by that
  gate; the publish job rejects any other ZIP)

Configure secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_ID_APPLICATION`
- `APPLE_NOTARY_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Before enabling `MACOS_016_QUALIFIED`, execute and retain every signing command
and physical matrix row in [the qualification checklist](macos-release-qualification.md).
These external prerequisites and physical checks have not been performed in
this workspace. A green build, test, or unsigned assembly does not satisfy the
support-publication gate.

## Prepare a release

1. Start `release/<version>` from the tested `main` commit, for example
   `git switch -c release/0.1.6`. Only release branches can publish; pushes to
   `main` never create a release.
2. On the release branch, replace the versioned changelog section's
   `Unreleased` marker with the publication date and change its comparison
   link from `HEAD` to the new tag.
3. Set the same SemVer value in `VERSION`, `build.zig.zon`, and
   `ui/linux/Cargo.toml`, then update `ui/linux/Cargo.lock`. The branch name
   must match that value exactly.
4. Run `zig build test`, `zig build check-darwin-core`,
   `zig build check-windows-core`, `cargo test --locked --manifest-path
   ui/linux/Cargo.toml`, and `cargo check --locked --manifest-path
   ui/linux/Cargo.toml` on supported Linux.
5. Run `scripts/package-release.sh`. It checks version agreement, builds both
   Linux executables, verifies `sayall --version`, and writes the Linux x86-64
   binary archive, source archive, and checksums to `dist/`. Inspect both
   archive listings; no Darwin or Windows compile output is installable or
   included.
6. Install the Linux x86-64 archive in a clean x86-64 Arch Linux environment
   running Omarchy and complete a manual recording, transcription, HUD,
   typing, restart, and uninstall smoke test.
7. On macOS 15 arm64, confirm the normal CI tests and ad-hoc unsigned assembly.
8. Commit the release preparation, merge that preparation into `main`, and push
   `main` first. The secret-capable AUR workflow runs from the default branch
   and requires its AUR templates and preparation script to match the release
   commit. Pushing `main` runs CI but cannot publish a release.
9. Push `release/<version>` to trigger the release workflow. Approve its
   protected signing/notarization job, download the exact `macos-assets`
   artifact, and complete the artifact commands and physical matrix in the
   macOS checklist. Record its SHA-256 and set the qualification variables only
   after an approver accepts that exact candidate, then approve the separate
   publish job. Repository build/test code never runs with release credentials
   available. The publish job creates the immutable `v<version>` tag at that
   exact commit and publishes the macOS ZIP, Linux/source archives, and combined
   checksums. A default-branch workflow then publishes all three AUR repositories
   from those immutable assets. Keep the release branch until AUR publication
   succeeds; it may then be deleted.

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
It can also be manually retried with an explicit version after a publishing
failure; the retry verifies the immutable release, tag, and matching release
branch before reading the AUR credential.
It uses a dedicated, unencrypted CI key stored in the `AUR_SSH_PRIVATE_KEY`
GitHub Actions secret. Its public-key fingerprint is stored in the
`AUR_SSH_KEY_FINGERPRINT` Actions variable and checked before any AUR access.
Add only that key's public half to the maintainer's AUR account; do not reuse a
personal or 1Password-managed SSH key. The workflow pins the AUR ED25519 host
key rather than trusting a dynamic `ssh-keyscan` result. Keeping the publishing
workflow on the default branch prevents release-branch workflow changes from
reading the AUR credential. The workflow also requires the preparation script
and all three AUR template directories on the default branch to match the
immutable release commit, preventing retries from combining old release assets
with newer package recipes.

`scripts/prepare-aur-release.sh` copies the checked-in `sayall`, `sayall-bin`,
and `sayall-git` templates, updates both stable package versions and final
checksums, and regenerates all three `.SRCINFO` files. The workflow checks the
public package ownership, clones all three standalone AUR repositories before
the first mutation, and then publishes `sayall-bin`, `sayall`, and `sayall-git`
in that order. Publishing the binary alternative first gives existing prebuilt
users a valid switch target before `sayall` changes to a source recipe. A retry
is safe: commits are never forced and repositories whose
generated files already match are skipped.

Set the `AUR_MAINTAINER` Actions variable to the AUR username that owns the
dedicated publishing key. That account must maintain `sayall`, `sayall-bin`,
and `sayall-git`; a package found under another maintainer causes the workflow
to stop before any AUR push.

Only after all three current packages are live, submit a manual AUR merge
request from `sayall-src` into `sayall` so its votes and comments follow the
canonical stable source package. Do not merge `sayall-src` first: existing
source users need a live target for their explicit one-time switch.

Before pushing the release branch:

1. Run a clean `makepkg` build in the `sayall` and `sayall-bin` package
   directories. Inspect (do not install) each package archive. Verify the
   packaged CLI reports the release version, both systemd units use `/usr/bin`,
   and licenses are under `/usr/share/licenses/<pkgname>`.
2. Run a clean `makepkg` build for `sayall-git`. Its `pkgver()` function
   derives the development version from Git and does not require an update for
   every upstream commit.
3. Test the transition paths. Upgrade an existing prebuilt `sayall`
   installation to the new stable source recipe, and explicitly switch another
   such installation with `yay -S sayall-bin`. Upgrade an existing
   `sayall-bin` installation in place and switch an existing `sayall-src`
   installation with `yay -S sayall`. Review each conflict-removal prompt, run
   `sayall setup` and `sayall doctor`, and complete a recording, transcription,
   HUD, and typing smoke test. Verify all switches preserve
   `~/.config/sayall/config.json`.
   The explicit command is required for users still running the 0.1.4
   `sayall-src` CLI; its older `sayall update` implementation cannot redirect
   itself to the later package name.
4. Repeat `sayall setup` after switching among all three mutually conflicting
   current variants and verify each switch preserves the selected or disabled
   shortcut state. Also test an upgrade with an existing manual
   `bind = CTRL, SLASH, exec, sayall toggle`: setup must leave the line intact
   while successfully restarting both services. Verify `sayall update` detects
   and targets `sayall`, `sayall-bin`, and `sayall-git`; retain `sayall-src`
   coverage only as a legacy migration fallback.
5. After the workflow succeeds, confirm the public pages for `sayall`,
   `sayall-bin`, and `sayall-git` show the intended versions and maintainer.
   Then request the `sayall-src` into `sayall` AUR merge.

## Service paths in packages

The checked-in systemd units intentionally target `%h/.local/bin` for the
documented manual installation. Distribution packages must install equivalent
units whose `ExecStart` paths use that package manager's installation prefix;
they must not patch users' existing units during upgrades.
