# Zephyr — for Zulip

**Zephyr** is a truly native Apple-platform client for [Zulip](https://zulip.com) —
macOS first, with iOS/iPadOS and visionOS builds from the same target and a
read-only tvOS channel monitor: a calm two-pane window in the
spirit of Apple Messages, with the web app's sidebar concepts (channels, folders,
topics, views) rendered natively. The name honors Zulip's ancestry in MIT's
Zephyr messaging system — and a zephyr is a soft, fast breeze, which is the feel the app
aims for. Zephyr is an independent project, not affiliated with the Zulip organization.

**Status: feature-complete through M4** (minus scheduled messages, deferred
deliberately). Everything in M2's messaging core plus: notifications with
inline reply (DMs + mentions, while running — Zulip has no desktop push), dock badge and
sounds — Zulip's own, louder for DMs and mentions (configurable in Settings ⌘,),
multi-account with switching, a channel
browser with subscribe/unsubscribe and muting, warm launch from a cached snapshot
("stale → live"), topic moves with propagation, read receipts, and an edit-history
viewer. Offline-first: warm launch from the cached snapshot, a per-account SQLite
message store (GRDB) retains full history for offline transcripts, offline
scrollback, and offline full-text search, drafts and the outbox survive
relaunch, sends that never reached the server queue and auto-resend on
reconnect, and reactions/read-state recorded offline replay when the network
returns (see ARCHITECTURE §9). Full Zulip-style keyboard navigation on both platforms
(hardware keyboards on iPad/iPhone included): j/k message selection, r reply,
s/S narrowing, n/p unread navigation, +/\* reactions and stars — press ? for
the complete map. A Recent Conversations view (t) mirrors the web app's:
recency-ordered conversations with unread counts and
include-DMs/unread/participated filters. Conversations open at the first
unread with a NEW marker and jump-to-latest; message links (/near/) land on
and highlight their target. Sign-in supports SSO (Google/GitHub/SAML) via
the mobile web-auth flow, plus password and manual API key. Topics can be
muted/followed, polls and to-do lists are interactive, GIFs animate, and a
Format menu (⌘B/⌘I/⌘K) wraps compose selections in markdown. The Xcode target is multiplatform — the same
scheme builds and runs on macOS 26+, iOS/iPadOS 26+ and visionOS 26+; AppKit-specific
behavior (Quick Look, popover search, Settings scene, dock badge) is gated behind
a small `Platform` shim. A separate `ZephyrTV` scheme builds the tvOS 18+ monitor.
Share and widget extensions ship on macOS and iOS. Preferences that describe
the person rather than the device (badge policy, sounds, sidebar order, send
key) sync between devices through iCloud's key-value store
(`Zephyr/SettingsSync.swift`); the App IDs `com.twarge.zephyr` and
`com.twarge.zephyr.tv` need the iCloud capability with key-value storage, and
the tvOS monitor prefills its server and email from the same store. Builds go to App Store Connect
(TestFlight) for iOS and macOS through `.github/workflows/appstore.yml`.

## Building

Open `Zephyr.xcodeproj` and run the `Zephyr` scheme, or from the command line:

```bash
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr build   # the app
make                                                        # tests + every platform build
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

Summary, at the top of the sidebar, summarizes recent channel topics using Apple's
on-device model on eligible Apple Intelligence devices — on-device AI summaries can be
wrong, so each row opens the real conversation. Red dots identify personal mentions
awaiting a response, blue dots identify unseen messages, and green checks show that you
replied or reacted. It refreshes itself: rows follow live events, edits and moves
re-check within the second, and a failed pass retries on a backoff. Devices without the
model show message previews. See the
[Summary implementation notes](docs/SUMMARY_VIEW_STUDY.md) for response rules and
history limits.

## Documents

- [docs/SPEC.md](docs/SPEC.md) — product specification: vision, the Messages-style
  information architecture, UX spec, and milestones.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — technical architecture: module layout,
  sync engine, content-rendering pipeline, concurrency, persistence, recovery, testing.
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — condensed, verified notes on the Zulip server API
  as this client uses it (auth, event system, endpoints, feature-level gates, HTML dialect).

## Ground rules

- Platforms: macOS 26+, iOS/iPadOS 26+, visionOS 26+ (tvOS 18+ for the monitor app), Swift 6.x, SwiftUI-first (AppKit interop only where measured needs demand it).
- Servers: Zulip Server 9.0+ (API feature level 277+), matching zulip-flutter's floor.
- License: [Apache-2.0](LICENSE) — matching the entire Zulip ecosystem (server, flutter,
  mobile, desktop are all Apache-2.0), so adapting or porting their code is license-clean
  with attribution.
- Sounds: Zephyr/Sounds are the Zulip web app's notification sounds (CC0, Stefan Mertens;
  "Zulip" by Vidsyn), except "Ding" (CC BY 3.0, [InspectorJ](https://freesound.org/s/411089/)).
  `swift Scripts/import-zulip-sounds.swift <zulip>/static/audio/notification_sounds`
  rebuilds them.
- Prior art: architecture consciously adapted from
  [zulip-flutter](https://github.com/zulip/zulip-flutter) (store/event design, content
  parser) and the design docs in
  [zulip-mobile/docs/architecture](https://github.com/zulip/zulip-mobile/tree/main/docs/architecture).
