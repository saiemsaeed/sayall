# macOS release qualification

This is the support-publication gate for SayAll 0.1.6 on Apple Silicon macOS
15.0 or later. Automated CI establishes build and test readiness only. The
external signing/notarization prerequisites and physical matrix have **not**
been completed in this workspace; do not mark the macOS release published or
supported from automation alone.

## Artifact and signing checklist

Run against the exact signed `macos-assets` artifact downloaded from the
completed protected signing/notarization job while the separate publish job
awaits qualification approval. `scripts/package-macos-release.sh` produces
only the unsigned local/CI input and is not qualification evidence. Record
command output with the release evidence; replace `VERSION` and identity
placeholders.

```sh
shasum -a 256 -c SHA256SUMS.macos
unzip -q sayall-VERSION-macos-arm64.zip -d qualification
codesign --verify --deep --strict --verbose=2 qualification/SayAll.app
codesign -dv --verbose=4 qualification/SayAll.app
codesign -dv --verbose=4 qualification/SayAll.app/Contents/Helpers/sayall-process
lipo -archs qualification/SayAll.app/Contents/MacOS/SayAll
lipo -archs qualification/SayAll.app/Contents/Helpers/sayall-process
vtool -show-build qualification/SayAll.app/Contents/MacOS/SayAll
vtool -show-build qualification/SayAll.app/Contents/Helpers/sayall-process
spctl --assess --type execute --verbose=4 qualification/SayAll.app
xcrun stapler validate qualification/SayAll.app
```

- [ ] ZIP filename is `sayall-VERSION-macos-arm64.zip` and its checksum appears
  in the release's combined `SHA256SUMS` (the assembly job's intermediate
  manifest is `SHA256SUMS.macos`).
- [ ] Both binaries report arm64 only and a macOS 15.0 minimum deployment.
- [ ] Bundle ID is `pro.saiem.sayall`; helper is bundled and not independently
  installed.
- [ ] Helper was signed before the containing app; both use the intended
  Developer ID Application identity and Hardened Runtime.
- [ ] Notarization was accepted, ticket stapled, Gatekeeper assessment accepted,
  and stapler validation succeeded.
- [ ] A clean download independently matches the published checksum.

## Physical Apple Silicon matrix

Use one row per clean/prior-install state and target-app/device combination.
Do not replace OS build or chip with generic marketing names. Link defects and
retain logs without credentials, transcripts, or audio.

| Date | Version | ZIP SHA-256 | macOS version/build | Mac model/chip | State (clean/prior) | Input device/default | Target app + field | Install/Gatekeeper | Mic/TCC | Control+/ + menu | AX/clipboard | Deepgram | Groq success/failure | 300 ms / 300 s / 45 s bounds | Update/uninstall | Result | Defects/evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| YYYY-MM-DD | 0.1.6 | `<sha256>` | `15.x (build)` | `model / M-series` | clean | built-in default | TextEdit normal field | pending | pending | pending | pending | pending | pending | pending | pending | pending | link |

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

## Publication decision

- [ ] All required rows pass or accepted limitations have linked release notes.
- [ ] No release-blocking defect remains open.
- [ ] Signing/notarization evidence is attached to the immutable candidate.
- [ ] Release approver records name, date, candidate SHA-256, and go/no-go.
- [ ] `MACOS_016_APPROVED_SHA256` equals that exact candidate SHA-256 before
  the protected publish job is approved.

Until every publication item is checked, describe 0.1.6 as implemented and
automatically ready, with the external/physical evidence gate pending.
