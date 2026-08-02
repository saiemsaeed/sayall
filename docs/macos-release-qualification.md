# macOS 0.2.0 and later release qualification

SayAll has published a signed Apple Silicon app since 0.1.7. This checklist is
the support-publication gate for DMG releases on macOS 15.0 or later. Releases
0.1.7 and 0.1.8 used the immutable historical ZIP contract. An incomplete gate
parks the candidate rather than weakening its criteria. Automated CI establishes
build and test readiness only. Do not publish a candidate until its exact signed
and notarized artifact completes this physical matrix.

## Artifact and signing checklist

Run against the exact signed `macos-assets` artifact downloaded from the
completed protected signing/notarization job while the separate publish job
awaits qualification approval. CI invokes the ad-hoc mode of
`scripts/package-macos-release.sh` to produce only the unsigned input; its
Developer ID mode can produce a local DMG but does not replace qualification
of the protected workflow's exact artifact. Record command output with the
release evidence; replace `VERSION` and identity placeholders.

```sh
shasum -a 256 -c SHA256SUMS.macos
mount=$(mktemp -d); trap 'hdiutil detach "$mount"; rmdir "$mount"' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount" sayall-VERSION-macos-arm64.dmg
codesign --verify --deep --strict --verbose=2 "$mount/SayAll.app"
codesign -dv --verbose=4 "$mount/SayAll.app"
codesign -dv --verbose=4 "$mount/SayAll.app/Contents/Helpers/sayall"
codesign -dv --verbose=4 "$mount/SayAll.app/Contents/Helpers/sayall-process"
lipo -archs "$mount/SayAll.app/Contents/MacOS/SayAll"
lipo -archs "$mount/SayAll.app/Contents/Helpers/sayall"
lipo -archs "$mount/SayAll.app/Contents/Helpers/sayall-process"
vtool -show-build "$mount/SayAll.app/Contents/MacOS/SayAll"
vtool -show-build "$mount/SayAll.app/Contents/Helpers/sayall"
vtool -show-build "$mount/SayAll.app/Contents/Helpers/sayall-process"
spctl --assess --type execute --verbose=4 "$mount/SayAll.app"
xcrun stapler validate "$mount/SayAll.app"
xcrun stapler validate sayall-VERSION-macos-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 sayall-VERSION-macos-arm64.dmg
```

- [ ] DMG filename is `sayall-VERSION-macos-arm64.dmg` and its checksum appears
  in the release's combined `SHA256SUMS` (the assembly job's intermediate
  manifest is `SHA256SUMS.macos`).
- [ ] The app, CLI, and processing helper report arm64 only and a macOS 15.0
  minimum deployment.
- [ ] Bundle ID is `pro.leets.sayall`; the processing helper remains private,
  while the bundled CLI is exposed by the explicit menu installation or
  Homebrew's symlink into the installed app.
- [ ] DMG contains exactly `SayAll.app` and an `Applications` symlink targeting
  `/Applications`; dragging the app and the Cask both preserve the bundle.
- [ ] The CLI and processing helper were signed before the containing app; all
  use the intended Developer ID Application identity and Hardened Runtime.
- [ ] App and final DMG notarizations were accepted and tickets stapled;
  Gatekeeper accepted the app and stapler validation succeeded for both.
- [ ] A clean download independently matches the published checksum.

## Physical Apple Silicon matrix

Use one row per clean/prior-install state and target-app/device combination.
Do not replace OS build or chip with generic marketing names. Link defects and
retain logs without credentials, transcripts, or audio.

| Date | Version | DMG SHA-256 | macOS version/build | Mac model/chip | State (clean/prior) | Input device/default | Target app + field | Install/Gatekeeper | Mic/TCC | Control+/ + menu | AX/clipboard | Deepgram | Groq success/failure | 300 ms / 300 s / 45 s bounds | Update/uninstall | Result | Defects/evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| YYYY-MM-DD | `<version>` | `<sha256>` | `15.x (build)` | `model / M-series` | clean | built-in default | TextEdit normal field | pending | pending | pending | pending | pending | pending | pending | pending | pending | link |

At minimum, qualify:

- [ ] A clean machine/user with no prior TCC grants, SayAll config, or SayAll
  Application Support state.
- [ ] A prior installation updated by quit, verified download, app replacement,
  relaunch, and version confirmation.
- [ ] Built-in microphone and one external default input device, including a
  default-device change between recordings.
- [ ] TextEdit or another standard editable field, a browser field, a secure
  field, and an app/field that rejects synthetic Command+V; verify clipboard fallback
  never auto-pastes into the wrong target.
- [ ] Microphone denied then granted, Accessibility denied then granted, focus
  changes during processing, Control+/ conflict, and menu-only operation.
- [ ] Deepgram success and network/auth/server failures; Groq disabled, success,
  and failure with raw-transcript warning/delivery.
- [ ] Normal streaming without REST, final PCM drain, network loss during
  recording with REST fallback, helper exit, and EU/global regional behavior.
- [ ] Minimum-duration rejection, five-minute cap, helper 45-second timeout,
  app quit during recording/processing, raw-audio cleanup on every terminal path, and
  startup scavenging after simulated interruption.
- [ ] No transcript/audio/key leakage in argv, logs, defaults, or persistent
  history; the plaintext shared config is mode `0600` and never logged.
- [ ] Manual update and complete uninstall, including deliberate shared-config
  retention or removal and Application Support cleanup.
- [ ] Menu installation of `/usr/local/bin/sayall`, `version`, `status`,
  `toggle`, `config init`, app replacement through upgrade, and symlink removal.
- [ ] Homebrew Cask install/upgrade/uninstall exposes a working `sayall` shim
  targeting `SayAll.app/Contents/Helpers/sayall`, remains compatible with the
  menu installer's ownership checks, and preserves `~/.config/sayall` unless
  explicit `--zap` is used.

## Publication decision

- [ ] All required rows pass or accepted limitations have linked release notes.
- [ ] No release-blocking defect remains open.
- [ ] Signing/notarization evidence is attached to the immutable candidate.
- [ ] Release approver records name, date, candidate SHA-256, and go/no-go.
- [ ] `MACOS_APPROVED_SHA256` equals that exact candidate before the protected
  publish job is approved.

Until every publication item is checked, the current supported macOS release
remains latest and the candidate must not be published.
