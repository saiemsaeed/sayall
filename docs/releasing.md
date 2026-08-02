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
| Apple Silicon arm64, macOS 15.0+ | Supported since 0.1.7; each release requires protected signing and physical qualification |
| Windows (`x86_64-windows` compile target) | Core compile readiness only; no app, runtime, package, or installable output |

Release binaries may work on related Linux Wayland systems, but that is not
part of the compatibility promise. The Darwin core check is distinct from the
native macOS app build. The Windows check is not a release artifact. See the
accepted [0.1.6 macOS ADR](adr-macos-0.1.6.md), the
[macOS qualification gate](macos-release-qualification.md), and the Linux-only
HUD/control [`protocol-v1 compatibility contract`](protocol-v1.md).

## macOS signing and qualification

Normal CI runs on macOS 15 arm64, tests, and ad-hoc assembles a clearly named
`-unsigned` ZIP without release credentials. That artifact is evidence of
automated readiness only and must not be published as the supported download.

`scripts/package-macos-release.sh` builds with a macOS 15 deployment target and
produces the tested, ad-hoc-signed CI candidate. On `release/<version>`, the Release
workflow rebuilds that candidate without credentials, verifies it before
credentials are exposed, then uses a protected job to sign the nested CLI and
processing helper first and the app second, notarize, staple, and
Gatekeeper-check the result. It then creates a DMG containing that one app and
an `/Applications` symlink, and notarizes, staples, and validates the final DMG.
Repository build or test code does not run while release credentials are
available, and an `if: always()` step removes the certificate, notary key, and
temporary keychain before the signed artifact is uploaded.

Create two protected environments with required reviewers, prevent self-review,
disable administrator bypass where operationally acceptable, and restrict both
to release branches. Keep their authority separate:

- `macos-signing` authorizes only signing/notarization. Configure the
  `APPLE_TEAM_ID` variable and all six Apple secrets below.
- `macos-publication` contains no signing credentials. Configure
  `MACOS_APPROVED_SHA256` only after the exact candidate is approved. The
  checked-in `VERSION` determines the release version, while the digest binds
  approval to one signed artifact; a stale digest cannot publish a later
  candidate.

Configure secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_ID_APPLICATION`
- `APPLE_NOTARY_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Execute and retain every signing command and physical matrix row in [the
qualification checklist](macos-release-qualification.md). A green build, test,
unsigned assembly, or successful notarization alone does not satisfy the
support-publication gate. If qualification is incomplete, do not approve the
publish job; move macOS publication to a later version rather than weakening
the gate.

## Prepare a release

1. Update local `main` to the tested `origin/main`, then create a non-triggering
   preparation branch such as `prep/0.1.8`. Do not use `release/*` for the
   preparation PR: any push to that pattern starts the protected release
   workflow.
2. On the preparation branch, move the user-visible changes from `Unreleased`
   into the versioned changelog section with the intended publication date and
   add its comparison link. If publication slips to another date, correct the
   changelog through another preparation PR rather than editing a release
   branch.
3. Set the same SemVer value in `VERSION`, `build.zig.zon`, and
   `ui/linux/Cargo.toml`, then update `ui/linux/Cargo.lock`.
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
7. Confirm the normal macOS CI test and ad-hoc unsigned assembly remain green;
   this is regression coverage only and produces no releasable artifact.
8. Commit and push the preparation branch, merge its PR, then fetch and
   fast-forward local `main` to the merged `origin/main`. Pushing `main` runs CI
   but cannot publish a release. The secret-capable AUR workflow later requires
   its templates and preparation script on the default branch to match the
   release commit.
9. Verify the worktree is clean and no same-version release branch, tag, or
   GitHub release already exists. Create `release/<version>` from the exact
   merged `origin/main` commit, assert both SHAs match, make no further edits or
   commits, and push it once to trigger the release workflow.
10. After the Linux, source, and unsigned macOS jobs succeed, approve the
    protected `macos-assets` job to sign, notarize, staple, and upload the exact
    candidate.
11. Download that exact `macos-assets` artifact while `publish` remains blocked.
    Complete the artifact checks and physical Apple Silicon matrix, record the
    approver, decision, and DMG SHA-256, then set `MACOS_APPROVED_SHA256` to
    that exact digest. Do not approve publication if any required row is
    incomplete.
12. Approve the protected `publish` job. It rejects any candidate whose digest
    differs from the approved value, creates the immutable `v<version>` tag at
    the exact release commit, and publishes Linux, source, and signed macOS
    archives with one checksum manifest. A default-branch workflow then
    publishes all three AUR repositories from those immutable assets. Keep the
    release branch until AUR publication succeeds; it may then be deleted.

If publication fails while the GitHub release is still a draft, rerun the exact
failed release commit; the workflow deletes and reconstructs the draft before
publishing. If the release is already published, do not rerun or move its tag.
Use the manual `Publish AUR` workflow with the immutable version when only AUR
publication needs retrying.

Do not move or recreate a published tag. Corrections receive a new patch
release. Enable **immutable releases** in the GitHub repository settings before
publishing the first tag; the workflow also refuses to overwrite existing
assets.

Treat a successfully published release branch as frozen. If publication
succeeds and a defect is found afterward, prepare a new patch version rather
than pushing replacement artifacts to the same branch.

## Automated Homebrew Cask publishing

The release workflow generates `sayall.rb` from the approved DMG version and
SHA-256 and retains it as the `homebrew-cask` workflow artifact. After the
release is published, the default-branch `Publish Homebrew Cask` workflow
independently downloads the immutable DMG and checksum manifest, verifies the
tag and release commit, regenerates the exact Cask, runs `brew style` and
`brew audit --cask`, and pushes `Casks/sayall.rb` to the dedicated
[`saiemsaeed/homebrew-sayall`](https://github.com/saiemsaeed/homebrew-sayall)
tap. It uses a write-enabled deploy key scoped only to that tap; the private key
is `HOMEBREW_TAP_SSH_PRIVATE_KEY` and its expected public fingerprint is
`HOMEBREW_TAP_SSH_KEY_FINGERPRINT`. The private key exists only in the
`homebrew-publication` environment, which permits deployment from `main`; Cask
generation, download, style, and audit run before the key is injected into the
final Git-only publication step. It does not share Apple credentials or a
general-purpose GitHub token.

The Cask uses the immutable GitHub release DMG, installs `SayAll.app`, and lets
Homebrew expose `Contents/Helpers/sayall`; it never uses `sha256 :no_check`.
Normal uninstall quits bundle ID `pro.leets.sayall` and removes Homebrew's app
and binary shim. Shared configuration is removed only by explicit `--zap`.
Manual retries require the immutable version and verify the matching release
branch, tag, asset, checksum, and generator before accessing the deploy key.
The publisher permits an equal-version idempotent retry but refuses to replace
the tap with an older version.

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
