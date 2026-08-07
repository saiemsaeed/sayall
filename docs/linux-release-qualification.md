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

After every required row passes, compare the exact `sha256sum SHA256SUMS` value
recorded above with the `candidate-identities` job summary before approving the
protected publish job. The publish job rejects a different manifest, thereby
binding both the Linux binary and source archive to this qualification.
Rebuilding workflow artifacts invalidates this approval even when the commit is
unchanged. Follow the full-rerun procedure in `releasing.md`, download the new
Linux artifact ID, repeat the complete Linux gate, and compare the new manifest
identity before publication approval.

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

## Severity and supported release cell

The sole blocking Linux cell is a current, fully updated x86-64 Arch Linux
installation running Omarchy with Hyprland Wayland. The archive is built and
qualified for that Arch environment; it is not a universal Linux archive.

A **P0** is a supported-cell failure that exposes a transcript to the wrong
target, leaks secrets or retained audio, duplicates delivery, or corrupts user
data/configuration. A **P1** is inability to install, launch, or complete
dictation in the supported cell; unbounded or stuck capture/processing/worker
behavior; or singleton/service failure that does not recover. Any P0 or P1 is a
release blocker. Lower-severity defects block only when the release approver
explicitly promotes them.

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
| Upgrade `sayall` from the immediately preceding public release or release candidate | ☐ | Record exact source version |
| Upgrade `sayall-bin` from the immediately preceding public release or release candidate | ☐ | Record exact source version |
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

## Blocking supported matrix

Run every row on the supported Omarchy/Hyprland Wayland cell. Every unchecked
row is a publication blocker for the current candidate.

| Behavior | Result | Evidence / notes |
| --- | --- | --- |
| Login starts one silent host; `status` is read-only | ☐ | |
| CLI and managed Hyprland shortcut each toggle exactly once | ☐ | |
| Capture level/timer update; cancellation returns to idle | ☐ | |
| Streaming succeeds; REST fallback occurs at most once | ☐ | |
| `type` delivers once to the field focused at delivery time | ☐ | Linux does not retain/revalidate the recording-start target |
| Focus change during recording and processing follows the documented delivery-time-focus rule without disclosure to any other field | ☐ | |
| Secure/password fields do not receive automatic disclosure; transcript is preserved safely with clear notice | ☐ | |
| Clipboard mode preserves exact text; type failure falls back once without auto-pasting into a different target | ☐ | |
| Missing key and microphone/permission failure use native error UI/notification and recover after correction | ☐ | |
| Built-in/default input and hotplug/default-input changes between recordings behave predictably | ☐ | Record PipeWire device/default |
| Raw audio is removed on success, cancellation, provider failure, worker/host kill, and timeout | ☐ | No transcript/key/audio leakage in argv, logs, or persistent history |
| Startup scavenges audio left by a simulated interruption without exposing it | ☐ | |
| Config change applies after restart without corruption | ☐ | |
| Worker crash/timeout is bounded and the next toggle recovers | ☐ | |
| Host kill is recovered by systemd with one owner and no stale socket | ☐ | |
| Logout/login restores expected shortcut state | ☐ | |

## Exploratory matrix (non-blocking)

Reuse the blocking behavior rows above in each environment; record deviations
but do not hold publication unless they reproduce in the supported cell or meet
a P0 privacy/integrity threshold. These cells are not supported until they are
intentionally adopted and packaged.

| Exploratory cell | Result | Evidence / notes |
| --- | --- | --- |
| Arch x86-64, X11 | ☐ | |
| Arch x86-64, GNOME portal session | ☐ | Portal consent/session-loss behavior |
| Arch x86-64, KDE portal session | ☐ | Portal consent/session-loss behavior |
| Ubuntu LTS, GNOME | ☐ | No Arch archive portability claim |
| Fedora current, GNOME | ☐ | No Arch archive portability claim |
| KDE on other distributions | ☐ | Record distribution/version |

Portal consent must occur only after the explicit Settings action. Declining or
closing the prompt must not prevent normal host startup or create a second
shortcut owner.

## Upgrade and rollback evidence

Upgrade from the actual immediately preceding public release (or the exact
candidate that would immediately precede this one). Record both versions and,
after the package transaction, run the newly installed `sayall setup` and retain:

```sh
systemctl --user status sayall.service sayall-hud.service --no-pager
journalctl --user -u sayall.service -u sayall-hud.service -b --no-pager
sayall doctor --json
```

The candidate fails qualification if the old service remains active, both hosts
handle a shortcut, text is delivered twice, the private worker is public, or a
stale socket prevents recovery.

Where the preceding version is 0.1.8, also retain the historical two-phase
service-retirement migration check. Keep `sayall-src`, manual-unit, keyword,
metrics-v1, and other historical migration fixtures as regression coverage;
they do not replace the immediately-preceding-version upgrade.

Before publication, prove rollback in a disposable environment: stop the
candidate host, downgrade all package-owned components together, reload the user
manager, and restore the prior service. Never mix candidate UI/CLI components
with a worker or daemon from the prior release. Record the exact package commands
and result here:

- Rollback result:
- Evidence / notes:

Run a minimum two-hour soak containing at least 50 complete toggle → capture →
process → delivery cycles, three intentional native-host kills followed by
systemd recovery, one worker kill, one logout/login, hotplug/default-input
changes, and sleep/wake where the test hardware supports it. Retain the
user-service journal, record cycle counts, and verify no audio remains after
each terminal path and after startup scavenging. Any duplicate delivery,
duplicate owner, unexpected service restart, unrecovered crash, stale socket,
or retained audio fails the soak.

- Soak start/end:
- Successful cycles:
- Intentional recovery cycles:
- Unexpected restarts:
- Journal/evidence location:

## Decision

- [ ] Every package-lifecycle and blocking supported-matrix row passed with the
  exact frozen candidate; exploratory results are recorded separately.
- [ ] Failures and deviations are linked to blocking issues.
- [ ] Release-candidate soak completed without duplicate owners or delivery.
- [ ] Rollback was demonstrated and approved.
- [ ] Approver, date, and decision are recorded below.

**Decision:** Pending  
**Approver:**  
**Date:**  
**Notes:**
