# AGENTS.md

This file applies to the entire repository. More specific `AGENTS.md` files in
subdirectories override it for files in their scope.

## Project overview

SayAll is a cross-platform voice-dictation application. The Zig daemon and CLI
live in `daemon/`; platform UIs live under `ui/`; packaging and release tooling
live in `scripts/`, `packaging/`, and `.github/workflows/`. Preserve the platform
and protocol boundaries described in `docs/adr-unified-core-cli-and-native-hosts.md`
and `docs/protocol-v1.md`.

## Development expectations

- Keep changes focused and avoid committing generated build output or secrets.
- Add or update tests when behavior changes, especially for protocol,
  configuration, persisted-format, and platform-boundary changes.
- Preserve explicit unsupported-platform behavior; a compile-readiness check is
  not evidence that a platform is supported.
- Treat audio, transcript, API keys, and provider payloads as sensitive. Do not
  add logging that exposes them.
- Follow `docs/releasing.md` for version or release changes. Do not publish,
  sign, notarize, or modify releases as part of an ordinary code change.

## Validation

Run the checks relevant to the files changed. The primary CI checks are:

```sh
zig build test
zig build check-darwin-core
zig build check-darwin-cli
zig build check-windows-core
cargo test --locked --manifest-path ui/linux/Cargo.toml
bash tests/homebrew-cask.sh
bash scripts/package-release.sh
```

Format changed Zig files with `zig fmt` and changed Rust files with
`cargo fmt --manifest-path ui/linux/Cargo.toml`. If a required check cannot run
in the current environment, state that clearly in the PR.

## Review priorities

When reviewing a change, prioritize actionable correctness, security, privacy,
data-loss, compatibility, lifecycle/concurrency, and release-safety defects.
Check that:

- IPC and worker protocol changes remain bounded, validated, and compatible.
- Recording, cancellation, and shutdown paths release resources deterministically.
- Configuration and persisted-state changes handle upgrades and invalid input.
- Linux, macOS, and unsupported-platform behavior remains intentionally separated.
- Tests exercise failure paths as well as successful behavior.

Do not report speculative style preferences as defects. Reference the affected
file and line and explain a concrete failure scenario for each finding.

## Requesting Codex review on GitHub

Repository setup is performed once by an administrator:

1. Open Codex while signed in to the ChatGPT account whose plan includes Codex.
2. Connect GitHub in Codex settings and install the OpenAI Codex GitHub app.
3. Grant the app access to this repository. Organization-owned repositories may
   require approval from a GitHub organization owner.
4. Optionally enable automatic pull-request reviews for this repository in the
   Codex code-review settings.

To request a review manually, open or update a pull request and add this comment:

```text
@codex review
```

Codex will review the current PR revision using these repository instructions.
After pushing fixes, comment `@codex review` again to request review of the new
revision. Resolve findings only after verifying them; Codex review supplements
CI and human review rather than replacing either.
