# ADR: Platform ownership and the 0.1.4 support contract

- **Status:** Accepted
- **Applies to:** SayAll 0.1.4
- **Date:** 2026-07-22

> The accepted [0.1.6 macOS architecture ADR](adr-macos-0.1.6.md) supersedes
> only this record's macOS composition/topology deferral. Linux and Windows
> ownership and support decisions remain in force.

## Context

SayAll is currently a Linux product: a Zig daemon and CLI are integrated with
Linux audio, input, desktop, and service facilities, while a Rust/GTK4 process
provides the Linux HUD. Future macOS and Windows products need native platform
integration, but choosing their process boundaries or generalizing the current
Linux interfaces before those requirements are known would turn guesses into
architecture.

This record defines ownership and support terminology before that work begins.
It is a boundary contract, not a claim that the current source tree has already
been separated into portable and platform-specific modules.

## Decision

### Ownership

- **Portable core:** Zig owns platform-independent product behavior, including
  transcription and cleanup orchestration, configuration and domain state,
  provider integrations, and portable capability semantics. Platform-specific
  operations reach that core through explicit boundaries as they are extracted.
- **Linux product and runtime:** the existing Zig daemon/CLI composition and
  its Linux integrations remain owned by the Linux layer. The existing
  Rust/GTK4 and gtk4-layer-shell HUD is also Linux-only product code. Linux owns
  PipeWire capture, text delivery, desktop notifications and shortcuts,
  process/service lifecycle, and Linux packaging.
- **macOS:** a future macOS layer will be native Swift/AppKit code and will own
  macOS UI, permissions, lifecycle, input, audio, and packaging integration.
- **Windows:** a future Windows layer will likewise be native and will own the
  corresponding Windows concerns. Its toolkit and implementation language are
  deliberately undecided.

The macOS and Windows entries describe future ownership boundaries only. They
do not assert that an implementation, package, artifact, or runnable product
exists for either platform.

### Support terms

These terms are independent and must not be used interchangeably:

- A **capability** is functionality implemented by a component and, where
  relevant, reported through an API. It says nothing by itself about whether a
  platform can run the functionality.
- **Runtime readiness** means the necessary native integrations and lifecycle
  work exist and pass end-to-end validation on a platform.
- An **OS permission** is a grant controlled by the operating system or user,
  such as microphone, accessibility, input-control, or notification access. A
  capable and runtime-ready build can still be unusable when permission is
  absent.
- A **supported platform** is a release commitment: SayAll builds, tests,
  packages, documents, and accepts defects for a stated platform matrix.

For 0.1.4, Linux is the only runtime-supported operating system. The narrower
Linux distribution, desktop, and architecture matrix stated in the README
remains the actual compatibility promise. Source-level portability or a
reported capability does not extend that promise. In particular, 0.1.4 makes
no macOS or Windows implementation, package, artifact, runtime-readiness, or
runtime-support claim.

`zig build check-darwin-core` and `zig build check-windows-core` are
compile-only source-readiness checks. They compile representative portable
orchestration and contracts with the explicit unsupported runtime and product
boundaries for aarch64-macos and x86_64-windows, respectively. The checks do
not run or install their foreign test artifacts, build a native CLI, adapt
Windows argv, produce packages, or expand the supported release matrix.

### Protocol and composition

[Control protocol v1](protocol-v1.md) is the current Linux HUD, control, and
external-observability API. It carries bounded state, command, metric, and event
messages over the current private Unix socket. It is not automatically a
future platform transport, PCM/audio transport, or privileged-operation
transport. Reusing or extending it for any of those purposes requires an
explicit decision, including security, privacy, backpressure, and
platform-lifecycle analysis.

The choice between a linked library and a packaged helper is deferred. A native
layer may link the Zig core as a library, or a release may package it as a
helper process with an IPC boundary. Neither composition is selected by 0.1.4,
and protocol v1 must not be treated as making that choice implicitly.

## Consequences

- **Permissions:** native layers request, explain, persist, and recover from OS
  permission state. The Zig core can report that an operation is unavailable or
  failed, but it does not manufacture permission or equate permission with a
  capability.
- **Lifecycle:** each platform layer owns launch, shutdown, single-instance,
  suspension, reconnection, and crash-recovery behavior appropriate to that OS.
  The current systemd services and independently reconnecting GTK HUD remain
  Linux decisions, not portable requirements.
- **Packaging:** artifacts include only the platform implementations they
  actually contain and validate. Linux packages continue to carry the current
  daemon/CLI, HUD, units, and Linux dependencies. Future signing, sandboxing,
  installers, native dependencies, and support declarations are decided per
  platform.
- **Transport:** in-process calls are possible for a linked core; authenticated,
  bounded IPC would be required for a helper. Control/observability, PCM data,
  and privileged operations may need separate transports and threat models.
- **Scope:** no cross-platform UI framework, speculative adapter, placeholder
  native target, or abstraction layer is introduced now. Native UI, permission,
  lifecycle, and packaging constraints differ substantially, and validated
  platform requirements must precede any shared abstraction. This keeps 0.1.4
  focused on documenting the boundary without creating unsupported surfaces.
