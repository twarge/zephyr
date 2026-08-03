# Zephyr — for Zulip

**Zephyr** is a truly native Apple-platform client for [Zulip](https://zulip.com) —
macOS first, with iOS/iPadOS builds from the same target: a calm two-pane window in the
spirit of Apple Messages, with the web app's sidebar concepts (channels, folders,
topics, views) rendered natively. The name honors Zulip's ancestry in MIT's
Zephyr messaging system — and a zephyr is a soft, fast breeze, which is the feel the app
aims for. Zephyr is an independent project, not affiliated with the Zulip organization.

**Status: feature-complete through M4** (minus scheduled messages and server draft
sync, deferred deliberately). Everything in M2's messaging core plus: notifications with
inline reply (DMs + mentions, while running — Zulip has no desktop push), dock badge and
send sounds (configurable in Settings ⌘,), multi-account with switching, a channel
browser with subscribe/unsubscribe and muting, warm launch from a cached snapshot
("stale → live"), topic moves with propagation, read receipts, and an edit-history
viewer. Offline: warm launch works from the cached snapshot with an automatic
15-second reconnect loop, and compose drafts persist across launches (per
conversation, per account). The Xcode target is now multiplatform — the same
scheme builds and runs on iOS 18+/iPadOS (Simulator-verified); AppKit-specific
behavior (Quick Look, popover search, Settings scene, dock badge) is gated behind
a small `Platform` shim. Remaining before public beta: Developer ID
signing/notarization (needs the account holder's credentials).

## Building

Open `Zephyr.xcodeproj` and run the `Zephyr` scheme, or from the command line:

```bash
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr build   # the app
swift test --package-path Packages/ZulipKit                 # package tests
swift run --package-path Packages/ZulipKit zulip-harness    # headless harness
```

The harness signs in (env vars, or `… zulip-harness login` to fetch a key interactively),
syncs, prints recent messages, and streams live events until ^C.

## Why

There is no native desktop Zulip client today. The official desktop app is an Electron
wrapper around the web app, and the official next-gen mobile client (zulip-flutter) runs on
macOS only as an unsupported dev target. This project fills that gap with a real Mac app:
SwiftUI, system notifications, Keychain, menu-bar/dock integration, and native text
rendering of Zulip's message content.

## Documents

- [docs/SPEC.md](docs/SPEC.md) — product specification: vision, the Messages-style
  information architecture, UX spec, and milestones.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — technical architecture: module layout,
  sync engine, content-rendering pipeline, concurrency, persistence, recovery, testing.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — condensed, verified notes on the Zulip server API
  as this client uses it (auth, event system, endpoints, feature-level gates, HTML dialect).

## Ground rules

- Platform: macOS 26+, Swift 6.x, SwiftUI-first (AppKit interop only where measured needs demand it).
- Servers: Zulip Server 9.0+ (API feature level 277+), matching zulip-flutter's floor.
- License: [Apache-2.0](LICENSE) — matching the entire Zulip ecosystem (server, flutter,
  mobile, desktop are all Apache-2.0), so adapting or porting their code is license-clean
  with attribution.
- Prior art: architecture consciously adapted from
  [zulip-flutter](https://github.com/zulip/zulip-flutter) (store/event design, content
  parser) and the design docs in
  [zulip-mobile/docs/architecture](https://github.com/zulip/zulip-mobile/tree/main/docs/architecture).
