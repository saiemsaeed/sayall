# Linux release qualification

Complete this checklist with the exact release candidate before approving
publication. CI, package-layout tests, and a successful build do not replace
physical desktop qualification. Start only after the `linux-assets` artifact
exists for the frozen `release/<version>` commit and while protected
publication is still blocked.

## Candidate record

- Release commit:
- Candidate version:
- Release workflow run and attempt:
- `linux-assets` artifact ID and upload digest:
- Linux archive SHA-256:
- Source archive SHA-256:
- Linux `SHA256SUMS` manifest SHA-256:
- `sayall` package archive SHA-256:
- `sayall-bin` package archive SHA-256:
- `sayall-git` package archive SHA-256:
- Tester and date:
- Hardware or VM:
- Distribution and kernel:
- Desktop/compositor and version:
- Session type (`echo "$XDG_SESSION_TYPE"`):

Copy the run, attempt, commit, artifact ID, and upload digest from the
`linux-assets` job summary. Download that immutable artifact ID directly and
verify its identity from a clean checkout of the release commit:

```sh
repo=saiemsaeed/sayall
artifact_id=ARTIFACT_ID
gh api -H 'Accept: application/octet-stream' \
  "repos/$repo/actions/artifacts/$artifact_id/zip" > linux-assets.zip
mkdir candidate
unzip -q linux-assets.zip -d candidate
cd candidate
sha256sum --check SHA256SUMS
sha256sum SHA256SUMS
git -C /path/to/sayall rev-parse HEAD
```

Use `gh api "repos/$repo/actions/artifacts/$artifact_id"` to confirm the
artifact name is `linux-assets`, its workflow-run ID and head SHA match the
recorded job summary, and it is not expired. The artifact ID, not only a run ID
and name, distinguishes rerun attempts. The checkout SHA must equal that frozen
release workflow SHA. Generate candidate AUR
recipes on an x86-64 Arch test system, using the downloaded immutable inputs:

```sh
version=$(tr -d '[:space:]' < /path/to/sayall/VERSION)
commit=RELEASE_COMMIT
binary_sha=$(awk -v f="sayall-$version-linux-x86_64.tar.gz" '$2 == f {print $1}' SHA256SUMS)
source_sha=$(awk -v f="sayall-$version.tar.gz" '$2 == f {print $1}' SHA256SUMS)
bash /path/to/sayall/scripts/prepare-aur-release.sh \
  "$version" "$commit" "$binary_sha" "$source_sha" aur-candidate
```

Seed `makepkg`'s `SRCDEST` with those two downloaded archives before building
the stable source and binary recipes; they must not download a not-yet-published
GitHub release. Install candidate package archives with `pacman -U`, not an AUR
helper pointed at the public packages.

After every required row passes, set the protected
`LINUX_APPROVED_MANIFEST_SHA256` environment variable to the exact
`sha256sum SHA256SUMS` value recorded above. The publish job rejects a different
manifest, thereby binding both the Linux binary and source archive to this
qualification. Any rerun of `linux-assets` invalidates the approval even when
the commit is unchanged: download the new attempt, repeat the complete Linux
gate, and replace the approved manifest digest.

The public `sayall-git` recipe intentionally follows moving `main`. To qualify
the release commit, make a disposable copy of its generated recipe, pin its Git
source with `#commit=$commit`, and make `pkgver()` return the generated static
`$version.r0.g<sha7>` value. Do not publish that pin. Record the resolved commit
and package version; after publication, separately confirm the moving public
recipe builds the then-current `main` successfully.

For AUR package rows, every command below must resolve to the locally installed
candidate package, not a checkout, public AUR package, or older manual
installation:

```sh
command -v sayall sayall-hud
pacman -Qo /usr/bin/sayall /usr/bin/sayall-hud \
  /usr/lib/sayall/sayall-process \
  /usr/lib/systemd/user/sayall-hud.service
sayall --version
sayall-hud --version
/usr/lib/sayall/sayall-process --version
sayall doctor
```

Record the three version outputs. They must identify one candidate version.
`command -v sayall-process` must fail because the worker is private.

## Package lifecycle matrix

Run each required row in a clean x86-64 Arch environment. Preserve a copy of
`~/.config/sayall/config.json` before destructive test setup and use a test API
credential, not a personal production secret.

| Test | Result | Evidence / notes |
| --- | --- | --- |
| Clean per-user install of exact Linux archive | ☐ | |
| Clean install `sayall` from source | ☐ | |
| Clean install `sayall-bin` | ☐ | |
| Clean build/install `sayall-git` | ☐ | |
| Upgrade `sayall` from 0.1.8 | ☐ | |
| Upgrade `sayall-bin` from 0.1.8 | ☐ | |
| Switch `sayall` ↔ `sayall-bin` ↔ `sayall-git` | ☐ | |
| Migrate installed `sayall-src` to `sayall` | ☐ | |
| Uninstall each current variant | ☐ | |

For every package install, upgrade, and switch:

1. Confirm `~/.config/sayall/config.json` and saved shortcut intent are
   preserved.
2. Run `sayall setup` twice; both runs must be safe and idempotent.
3. Confirm exactly one owner and one packaged service:

   ```sh
   systemctl --user is-active sayall-hud.service
   systemctl --user is-enabled sayall-hud.service
   ! systemctl --user is-active --quiet sayall.service
   systemctl --user cat sayall-hud.service
   pgrep -a -u "$USER" 'sayall|sayall-hud'
   ```

4. Confirm the desktop launcher opens the singleton Settings window and a
   login/logout cycle starts the host without opening Settings.
5. Run the functional matrix below.

For the standalone archive, verify the three versions directly from its
extracted files, install below `~/.local`, and confirm the installed unit uses
`%h/.local/bin/sayall-hud --autostart`. `pacman -Qo` does not apply to this row.
Exercise setup, login startup, the functional matrix, and removal of every
manually installed archive file separately from the AUR package rows.

For package uninstall, disable the shortcut and service while the CLI still exists,
remove the package, run `systemctl --user daemon-reload`, and verify no package
binary, desktop file, icon, or system unit remains. User configuration must
remain unless the tester explicitly removes it.

## Functional parity matrix

Run on supported Omarchy/Hyprland Wayland, an X11 session, and representative
GNOME and KDE portal sessions. Every checkbox below that is not explicitly
`N/A` is a publication blocker for the current candidate.

| Behavior | Wayland/Hyprland | X11 | GNOME/KDE portal | Evidence / notes |
| --- | --- | --- | --- | --- |
| Login starts one silent host | ☐ | ☐ | ☐ | |
| `sayall status` is read-only | ☐ | ☐ | ☐ | |
| `sayall toggle` starts/stops exactly once | ☐ | ☐ | ☐ | |
| Native shortcut toggles exactly once | ☐ | N/A | ☐ | |
| Capture level and timer update | ☐ | ☐ | ☐ | |
| Streaming transcription succeeds | ☐ | ☐ | ☐ | |
| REST fallback succeeds once | ☐ | ☐ | ☐ | |
| Type delivery targets the focused app | ☐ | ☐ | ☐ | |
| Clipboard mode preserves exact text | ☐ | ☐ | ☐ | |
| Type failure falls back once to clipboard | ☐ | ☐ | ☐ | |
| Cancellation returns to idle | ☐ | ☐ | ☐ | |
| Config change applies after host restart | ☐ | ☐ | ☐ | |
| Missing key uses native error UI/notification | ☐ | ☐ | ☐ | |
| Microphone failure uses native error UI/notification | ☐ | ☐ | ☐ | |
| Worker crash is bounded and next toggle recovers | ☐ | ☐ | ☐ | |
| Host crash restarts without a stale socket owner | ☐ | ☐ | ☐ | |
| Logout/login restores expected shortcut state | ☐ | ☐ | ☐ | |
| Portal restart/session loss downgrades status safely | N/A | N/A | ☐ | |

Portal consent must occur only after the explicit Settings action. Declining or
closing the prompt must not prevent normal host startup or create a second
shortcut owner.

## Upgrade and rollback evidence

The 0.1.8 upgrade is intentionally two-phase. After the package transaction,
run the newly installed `sayall setup` and retain:

```sh
systemctl --user status sayall.service sayall-hud.service --no-pager
journalctl --user -u sayall.service -u sayall-hud.service -b --no-pager
sayall doctor --json
```

The candidate fails qualification if the old service remains active, both hosts
handle a shortcut, text is delivered twice, the private worker is public, or a
stale socket prevents recovery.

Before publication, prove rollback in a disposable environment: stop the
candidate host, downgrade all package-owned components together, reload the user
manager, and restore the prior service. Never mix candidate UI/CLI components
with a worker or daemon from the prior release. Record the exact package commands
and result here:

- Rollback result:
- Evidence / notes:

Run a minimum two-hour soak containing at least 50 complete toggle → capture →
process → delivery cycles, three intentional native-host kills followed by
systemd recovery, and one logout/login. Retain the user-service journal and
record the cycle counts. Any duplicate delivery, duplicate owner, unexpected
service restart, unrecovered crash, or stale socket fails the soak.

- Soak start/end:
- Successful cycles:
- Intentional recovery cycles:
- Unexpected restarts:
- Journal/evidence location:

## Decision

- [ ] Every non-`N/A` row passed with the exact frozen candidate.
- [ ] Failures and deviations are linked to blocking issues.
- [ ] Release-candidate soak completed without duplicate owners or delivery.
- [ ] Rollback was demonstrated and approved.
- [ ] Approver, date, and decision are recorded below.

**Decision:** Pending  
**Approver:**  
**Date:**  
**Notes:**
