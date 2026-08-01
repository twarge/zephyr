# Architecture — Zulip for macOS

This document defines the technical architecture. It deliberately adapts the design of
[zulip-flutter](https://github.com/zulip/zulip-flutter) — the official next-gen client,
whose store/event/content design is battle-tested — translated into Swift 6 idioms.
Protocol facts it depends on are collected in [PROTOCOL.md](PROTOCOL.md).

## 1. Principles (inherited and adapted)

1. **Crunchy shell, soft center.** All network JSON is validated into typed models at the
   API boundary; interior code never inspects raw JSON or handles server quirks.
   (From zulip-mobile's
   [crunchy-shell.md](https://github.com/zulip/zulip-mobile/blob/main/docs/architecture/crunchy-shell.md).)
2. **The store is always a consistent snapshot of server state.** A `PerAccountStore` is
   only ever (a) constructed from a `/register` initial snapshot, and (b) mutated by
   applying events from that snapshot's queue, in order, by a single writer. There is no
   third way to change it.
3. **On any doubt, rebuild from a fresh snapshot.** Queue expired? Event application threw?
   Discard the whole store, `/register` again, swap in a new store. Correctness comes from
   the cheapness of rebuild, not from heroic incremental repair. (zulip-flutter does
   exactly this, including for its own bugs — "the show must go on".)
4. **Forward compatibility is designed in, not patched in.** Unknown event types decode to
   `.unexpected` (logged, skipped); unknown message HTML becomes an `.unimplemented` AST
   node that renders visibly. New server features degrade gracefully by construction.
5. **Every layer has a fake.** The API connection, the store backend, and platform
   services are protocols with test doubles; the model layer is UI-free and fully
   unit-testable.

## 2. Module layout

SwiftPM workspace: platform-independent packages + one app target.

```
zulip-macos/
├── Packages/
│   ├── ZulipAPI/        # protocol bindings — no app logic
│   │   ├── ApiConnection      (realm URL, credentials, feature level, URLSession)
│   │   ├── Routes/            (one func per endpoint: registerQueue, getEvents,
│   │   │                       getMessages, sendMessage, updateMessageFlags, …)
│   │   ├── Models/            (Codable: Message, User, Channel, Subscription,
│   │   │                       InitialSnapshot, …)
│   │   └── Events/            (Event enum decoded by type/op; .unexpected fallback)
│   ├── ZulipModel/      # the data layer — pure Swift, no UI imports
│   │   ├── GlobalStore / PerAccountStore (+ substores)
│   │   ├── UpdateMachine      (register → poll → apply → recover)
│   │   ├── Narrow             (first-class narrow types)
│   │   ├── MessageListModel   (per-view message list view-model)
│   │   ├── ConversationList   (unified sidebar model)
│   │   └── Unreads / TypingStatus / Presence / Autocomplete
│   └── ZulipContent/    # message HTML → typed AST (parser only, no rendering)
├── App/                 # the macOS app target (SwiftUI)
│   ├── Views/           (sidebar, transcript, compose, content renderer, settings)
│   ├── Auth/            (login UI, web-auth flow, Keychain)
│   └── Platform/        (notifications, badge, sounds, Quick Look, file panels)
└── Harness/             # M0 CLI/debug target driving ZulipModel headlessly
```

Dependency rule: `App → {ZulipModel, ZulipContent, ZulipAPI}`, `ZulipModel → ZulipAPI`,
`ZulipContent → nothing`. Packages never import AppKit/SwiftUI (Foundation only), keeping
them portable and testable from the command line.

## 3. API layer (`ZulipAPI`)

- **`ApiConnection`**: realm URL, email + API key (precomputed Basic-auth header),
  mutable `zulipFeatureLevel`, a `URLSession`, and the `User-Agent`
  (`ZulipForMac/<version> (macOS <os>)`). One instance per logged-in account. Feature-gated
  behavior lives in route functions (`if connection.featureLevel >= N …`), keyed to the
  floor in PROTOCOL.md §5.
- **Routes** are free functions/namespaced statics taking an `ApiConnection` — mirrors
  zulip-flutter's `api/route/*`; trivially fakeable.
- **Models** use `Codable` with *strict* decoding: required fields are non-optional and
  decode failures throw (crunchy shell). Server-optional-by-feature-level fields are the
  only optionals.
- **Events**: `enum Event` decoded via `type`/`op` discriminators into typed payload
  structs, with `case unexpected(type: String, raw: Data)` for unknowns. Exhaustive
  `switch` in the store means the compiler flags unhandled event types when we add cases.
- **Errors**: typed `ApiError` (code, message, HTTP status) — notably
  `BAD_EVENT_QUEUE_ID`, `RATE_LIMIT_HIT` (carries `retry-after`), auth failures. Rate
  limits honored via response headers; retries use per-request exponential backoff
  (a `BackoffMachine` value type, copied concept-for-concept from flutter).

## 4. Store layer (`ZulipModel`)

### GlobalStore and PerAccountStore

- **`GlobalStore`** (`@MainActor @Observable`): the account list (realm URL, user id,
  email, server version/feature level, realm name/icon — API keys live in Keychain, not
  here), global settings, and a map `accountID → PerAccountStore`. Async
  `perAccount(id:)` dedupes concurrent loads. Backed by a `GlobalStoreBackend` protocol
  (live: small persisted file + Keychain; test: in-memory).
- **`PerAccountStore`** (`@MainActor @Observable`): the consistent snapshot. Composed of
  substores (separate files, one flat facade): realm settings, users, channels +
  subscriptions, messages, emoji, unreads, recent-DM conversations, topics, typing,
  presence. Constructed *only* by `init(snapshot: InitialSnapshot)`.
- **Single writer**: only `UpdateMachine` calls `store.handleEvent(_:)`. Event application
  is synchronous on the main actor — events are small; heavy work (content parsing) is
  kept out of the event path.

Why `@Observable` rather than flutter's manual `ChangeNotifier` fan-out: SwiftUI's
observation is property-grained — views re-render only for properties they read — which
gives us most of the granularity flutter had to build by hand. The one place we keep
explicit registration is the message list (below), because per-message updates need
targeted invalidation, not list-identity churn.

### UpdateMachine

A state machine owning the store's connection to the event system:

```
loading ──register ok──▶ polling ──long-poll ok──▶ polling (apply events, advance lastEventId)
   ▲  ╲                     │
   │   ╲ transient error     ├─ transient error ─▶ recovering (backoff, dont_block retry,
   │    ╲ (backoff, retry)   │                      store.isRecoveringEventStream = true)
   │                         ├─ BAD_EVENT_QUEUE_ID ─▶ REBUILD
   │                         └─ event-apply threw  ─▶ REBUILD (rate-capped, shared 60s max backoff)
   └────────────── REBUILD: fresh /register → new PerAccountStore → atomic swap → dispose old
```

- Register params: `apply_markdown: true`, the client-capabilities set in PROTOCOL.md §2,
  a long `idle_queue_timeout` (desktop is a persistent poller; expiry still handled).
- Errors surface to UI only after ~5 consecutive failures ("Connecting…" banner via
  `isRecoveringEventStream`); backoff resets on success.
- 401 / server-below-floor → sign the account out (with UI explanation).
- The store never polls itself; `UpdateMachine` is separately owned and testable
  (feed it fake event sequences, assert store state).

### Message store and message lists

Adapted directly from zulip-flutter's proven split:

- **`MessageStore`** (substore): canonical `[Int: Message]` of every fetched message, plus
  the set of registered `MessageListModel`s. Events are applied to the canonical message
  once, then fanned out to registered lists.
- **`MessageListModel`** (one per open transcript, `@Observable`): a `Narrow`, a sorted
  message array, a parallel memoized-AST array, derived display items (date separators,
  sender-group boundaries, unread marker), `haveOldest`/`haveNewest`, fetch status with
  backoff, and a generation counter to cancel stale fetches after reset.
- **Anchor + two slices**: lists open at an anchor (newest / first-unread / message id) and
  fetch ~100 both directions; `fetchOlder`/`fetchNewer` are safe to call every scroll tick
  (no-op while busy / at end).
- **The reconcile rule** (copied verbatim in spirit — this encodes the core consistency
  invariant): when a fetch returns a message already in the canonical map, *keep the stored
  copy* (it has events applied that the fetch may predate) — except messages in
  unsubscribed channels (no events arrive for those; take the fetched copy). Messages from
  a `message` event always overwrite.
- **In-place updates**: edits mutate the canonical message and invalidate that one
  message's parsed AST; reactions/flags mutate and notify only lists containing the id;
  topic moves are handled per-narrow (topic-narrow lists follow the move; channel lists
  recompute; moved-out removes).
- **Outbox**: optimistic sends create a local `OutboxMessage` (client-generated
  `local_id`), appended to lists that `haveNewest`; the arriving `message` event carries
  `local_message_id` and replaces it. Failure → "not delivered, retry" state.

### Narrows and the conversation list

- `enum Narrow`: `combinedFeed`, `channel(id)`, `topic(channelID, topic)`, `dm([userID])`,
  `mentions`, `starred`, `search(query)` — each knows `containsMessage(_:)` and its API
  encoding (modern operators only; floor FL 277).
- **`ConversationList`** (the sidebar model — our main new component over flutter):
  a recency-sorted collection of `Conversation` values
  (`.dm(participants)` / `.topic(channelID, topic)`) with lastMessage snippet/timestamp,
  unread state, mute/follow state. Seeded from `recent_private_conversations` +
  `unread_msgs` + one combined-feed fetch (newest anchor, ~300 back) to establish topic
  recency; maintained from message/update/delete/flags events; scope filters (All/Unread/
  DMs/Mentions/Starred) are cheap derived views. Topic conversations are keyed
  `(channelID, lowercasedTopic)` and follow topic moves/renames.

## 5. Content pipeline (`ZulipContent` + App renderer)

The single biggest piece of bespoke work. Zulip messages arrive as server-rendered HTML in
a *closed, known dialect* (one renderer produces it), which makes a whitelist parser
tractable — zulip-flutter proves this at ~2,300 lines.

- **Parse**: HTML (SwiftSoup or a minimal DOM layer) → immutable AST. Sealed node
  hierarchy: block nodes (paragraph, heading, list, quote, code block with
  language + token-type spans, spoiler, table, math block, image gallery, embed) and
  inline nodes (text runs with style flags, link, mention, emoji, inline code, inline
  math, time). **Strict matching**: each rule matches exact element + class structure;
  anything else becomes `.unimplemented(rawHTML)` — never guessed at, never dropped.
  Precompute per-block link lists (flutter's `links` optimization) for interaction setup.
- **Parse policy**: pure function `parse(html) → Content`, run off-main (messages parse in
  batches on a background executor during fetch; single messages re-parse on edit), cached
  per message id + edit timestamp alongside the message list.
- **Render** (App layer): one exhaustive `switch` over block nodes → SwiftUI views; inline
  runs build a single `AttributedString` per paragraph (custom attributes for mentions,
  emoji, links, code voice) rendered with `Text`, with tap/hover resolution via the
  precomputed link list. Mention pills and reactions are the two places we accept custom
  drawing. Code blocks map Pygments token classes → semantic colors (both appearances).
  `.unimplemented` renders as a visible "unsupported content — open on web" chip; debug
  builds show the raw HTML.
- **v1 node inventory and the HTML dialect**: PROTOCOL.md §7. Math renders as styled TeX
  source in v1 (flutter's KaTeX-span renderer is a large sub-project; deferred).
- **Media**: thumbnails load from the server's thumbnail URLs with the auth header via a
  small authenticated-image loader (URLCache-backed); full-size opens in Quick Look via
  the temporary-public-URL endpoint. Never put credentials in URLs.

## 6. Transcript scrolling (the known-hard problem)

Requirements: open at first-unread anchor; prepend older history with **zero visual jump**;
stick-to-bottom when at newest; 60fps with thousands of rows of variable height.

zulip-flutter solves this with two slivers growing in opposite directions from a center
anchor. SwiftUI has no direct equivalent, so this is our highest-risk UI area:

- **Plan A (try first)**: `ScrollView` + `LazyVStack` with `scrollPosition(id:)` /
  `defaultScrollAnchor`, `onScrollGeometryChange` driving fetchOlder/fetchNewer.
  Acceptance test: prepend 100 variable-height rows with no visible offset shift, on a
  transcript of 5,000 rows.
- **Plan B (escape hatch, decided by measurement in M1)**: `NSViewRepresentable` wrapping
  `NSScrollView`/`NSCollectionView` where we control contentOffset compensation during
  prepend ourselves (the two-slice model maps cleanly onto this).

The `MessageListModel` is deliberately UI-agnostic (items + anchors in, scroll intents
out) so Plans A/B swap without touching the model.

## 7. Auth and accounts

- **Realm entry**: user enters a realm URL → unauthenticated `GET /server_settings` →
  drive the login UI from `external_authentication_methods` + `email_auth_enabled`.
- **Password realms**: native fields → `POST /fetch_api_key`.
- **SSO realms** (Google/GitHub/SAML/…): `ASWebAuthenticationSession` opening the realm
  login URL with `mobile_flow_otp=<random 64-hex OTP>`; the `zulip://login` redirect is
  captured by the session; API key = XOR-decrypt of `otp_encrypted_api_key` (PROTOCOL.md §1).
  This is the mobile flow, which (unlike the desktop app's flow) yields a real API key.
- **Fallback**: manual API-key entry (Settings → copy key from web).
- **Storage**: API keys in Keychain (`kSecAttrAccessibleAfterFirstUnlock`, per
  realm+email); account metadata in Application Support. This improves on flutter, which
  keeps keys in SQLite.
- Multi-account is structural from day one (`GlobalStore` maps accounts → stores; each has
  its own `UpdateMachine`); only the account-switching UI is deferred to M3.

## 8. Concurrency model

- Swift 6 strict concurrency, no `@unchecked Sendable` without a written justification.
- Stores and view-models: `@MainActor`. Event application is main-actor (events are small
  and this guarantees snapshot consistency without locking — same reasoning as flutter
  applying events on its UI isolate).
- Off-main: all networking (async URLSession), content parsing (batch + single), image
  decoding, search. Results hop to the main actor to mutate state.
- Long-poll loop: a structured `Task` owned by `UpdateMachine`, cancelled on account
  sign-out/store rebuild; presence ping and typing-notification timers likewise structured.

## 9. Persistence

- **v1 (matches flutter's shipping state)**: persist only account metadata (file) +
  API keys (Keychain) + UI state (window/frame, per-conversation drafts, in
  `UserDefaults`/file). Everything server-side is refetched via `/register` on launch.
  Launch shows the sidebar skeleton immediately, populated when the snapshot lands.
- **M4 offline cache**: GRDB/SQLite — persisted latest snapshot for instant warm launch
  (render stale, reconcile via fresh register — the "stale → live" pattern from
  zulip-mobile's realtime.md), plus a message cache per conversation. Kept out of v1
  deliberately: flutter's history shows staleness/rehydration is where the bug surface
  lives (their RN predecessor's chronic bugs; their own cache is still future work).
  If notification/share extensions ever need shared data, the DB moves to an App Group
  container (flutter does this on iOS for push decryption).

## 10. Notifications and platform services (App layer)

- `UNUserNotificationCenter` local notifications from `message` events, filtered by the
  store's per-channel/realm notification settings and self-authorship; inline-reply action
  posts through the normal send path; "mark read" action updates flags. Deduplicate against
  focused-conversation state (no banner for the transcript you're reading).
- No push when not running (protocol limitation — PROTOCOL.md §6): document clearly; the
  M3 menu-bar mode (app keeps polling with windows closed) is the honest mitigation.
- Dock badge from `Unreads` (policy configurable). Sounds via system sounds.

## 11. Testing strategy

- **API**: route functions against a `FakeApiConnection` (canned responses, recorded
  requests); decoding tests against captured real payloads.
- **Model**: the workhorse layer — feed `(InitialSnapshot, [Event])` sequences into a
  store and assert state; property: applying events one-by-one ≡ fresh register at the end
  (consistency invariant). UpdateMachine tested with scripted error sequences (expiry,
  transient failures, mid-apply throw) asserting rebuild behavior.
- **Content**: corpus tests — fixture files of real rendered HTML (captured from a live
  server per feature: mentions, code, math, spoilers, media…) → snapshot the parsed AST;
  a CI-refreshable corpus catches server dialect drift. Invariant tests (e.g. link-list
  precomputation matches tree walk).
- **UI**: ViewInspector/snapshot tests for content rendering; XCUITest smoke for auth +
  send + scroll; the M0 harness doubles as an integration test against a local
  `zulip/zulip` dev server in CI (weekly job, not per-PR).

## 12. Risks

| Risk | Mitigation |
|---|---|
| SwiftUI transcript scroll stability (prepend jump, perf) | Acceptance tests in M1; Plan B AppKit fallback behind the UI-agnostic list model (§6) |
| HTML dialect coverage / server drift | Whitelist parser + visible `.unimplemented` + refreshable fixture corpus; dialect is closed and versioned by feature level |
| No push notifications when app closed | Documented honestly; menu-bar background mode in M3 |
| KaTeX math | Explicitly deferred: TeX source in v1 |
| Server API evolution | Feature-level gating discipline (floor 277), `.unexpected`/`.unimplemented` escape hatches, changelog watch |
| Solo-project scope creep | Milestones each end daily-drivable; web-app deep links instead of parity features |
