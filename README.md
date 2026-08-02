# Zulip for macOS

A truly native macOS Zulip client, designed to feel like Apple Messages: a calm two-pane
window, a unified conversation list, and a focused transcript — instead of the dense
multi-column web UI.

**Status: M0 (foundations).** The `ZulipAPI` and `ZulipModel` packages are in place — typed
API bindings, the per-account store, and the register→poll→rebuild sync engine — plus the
Xcode app project with a placeholder window. The real UI lands in M1.

## Building

Open `Zulip.xcodeproj` and run the `Zulip` scheme, or from the command line:

```bash
xcodebuild -project Zulip.xcodeproj -scheme Zulip build     # the app
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
