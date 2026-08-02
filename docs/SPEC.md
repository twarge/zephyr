# Product Specification — Zulip for macOS

Working title: **Zulip for macOS** (final name TBD; it is a third-party client, so the
shipping name/icon must not imply it is official — see Open questions).

## 1. Vision

Zulip's model — channels divided into topics, plus direct messages — is the best
conversation model in team chat, but every existing client presents it with dense,
web-derived chrome. This app presents Zulip through the calmest UI Apple ships: the
Messages app. One window, two panes, a recency-sorted list of conversations on the left, a
single focused transcript on the right, compose at the bottom. Everything else (channel
browsing, search, settings) stays out of the way until summoned.

The organizing idea (revised after using the first prototype): **the sidebar holds the
things you'd name — channels and people — and topics are structure inside a channel.**
An early prototype tried a unified recency-sorted inbox of topics; in practice topics are
too ephemeral to be top-level siblings of DM threads. Channels + DMs on the left; on the
right, a channel reads as one interleaved feed with topic headers you can click to focus.

## 2. Goals and non-goals

Goals

- Feel native: SwiftUI, system typography and materials (Liquid Glass on macOS 26+),
  system notifications with inline reply, Keychain, dock badge, full keyboard control,
  VoiceOver.
- Feel like Messages: unified conversation list, one calm focused transcript, minimal chrome.
- Be genuinely fast: instant launch to cached UI, 60fps scrolling of long histories,
  native text rendering (no webviews anywhere).
- Stay correct under Zulip's real-time event system: the store is always a consistent
  snapshot of server state (see ARCHITECTURE.md).

Non-goals (initially)

- Feature parity with the web app. Realm/channel administration, detailed settings
  management, stats, etc. deep-link to the web app instead.
- Offline-first. Like zulip-flutter today, v1 refetches state on launch; a local message
  cache is a later milestone.
- Servers older than Zulip 9.0 (feature level 277).
- iOS/iPadOS. The model packages are kept platform-independent so a port stays possible,
  but no UI work targets it.
- Reimplementing Zulip's markdown. We render the server's HTML; we never parse markdown
  ourselves.

## 3. Platform requirements

- macOS 26 or later (developed on macOS 27 / Xcode 27; deployment target 26 keeps one
  prior major release covered while allowing the current design language and SwiftUI APIs).
- Swift 6.x with strict concurrency. SwiftUI app lifecycle.
- Distribution: Developer ID + notarization first; Mac App Store later if desired.
  App Sandbox enabled from day one (network client, user-selected file access).

## 4. Information architecture

### The core mapping

| Zulip concept | This app |
|---|---|
| DM conversation (1:1 or group) | Sidebar row in the Direct Messages section (like a Messages thread) |
| Channel | Sidebar row in the Channels section; opens the channel feed |
| Channel feed | Detail view: the channel's messages interleaved across topics, with clickable topic headers |
| Channel topic | A header run inside the channel feed; clicking it focuses a single-topic transcript |
| Combined feed / interleaved "all messages" | Not reproduced |

### Window layout

`NavigationSplitView`, two columns, unified toolbar:

- **Sidebar** (min ~280pt), modeled on the Zulip web app's left rail: a filter field,
  a **Views** section (Combined feed, Mentions, Starred; Inbox/Recent later), compact
  one-line **Direct Messages** rows (presence dot, name, bot marker, count badge), then
  channels grouped by **channel folder** (Zulip 12+; one flat Channels section on older
  servers) — colored type glyph (`#`/lock/globe), name, gray count badge; pinned first,
  muted dimmed and last.
- **Detail**: the selected channel's feed (topic headers interleaved) or a DM/topic
  transcript, compose bar at the bottom. A channel's topic list is one click away from
  the feed toolbar; a topic transcript links back to its channel via the toolbar chip.
- No third column. "New conversation" is a summoned flow, keeping the Messages
  silhouette.

### Sidebar row anatomy

- DM rows: avatar, name(s), snippet (last message, plaintext-flattened), relative
  timestamp, unread blue dot / `@` mention badge.
- Channel rows: circular badge in the channel's color with a `#` (lock when private)
  glyph, name, unread count badge; bell-slash and dimmed when muted.
- Context menus (later): mark read, mute/unmute, pin, copy link.

### Data sources

DM recency/snippets seed from `recent_private_conversations` + `unread_msgs` + a
combined-feed fetch, maintained live from message events. Channel rows come straight
from subscriptions; their unread badges aggregate per-topic unreads. Channel feeds and
topic transcripts are anchor-fetched message lists (ARCHITECTURE.md §4).

## 5. Transcript (conversation view)

### Header

Compact title bar area: conversation title (topic name or DM participants), channel chip
(clickable → channel view), participant avatars, follow/mute toggle, search-in-conversation.
For DMs: presence dot on the avatar.

### Message presentation

**No bubbles.** A flat, linear transcript — the presentation zulip-flutter and the web app
use — with Messages' calm coming from whitespace, materials, and restraint rather than
bubble chrome:

- All messages left-aligned in a single full-width content column. Sender header (avatar,
  name, time) once per group; consecutive messages from the same sender within 5 minutes
  coalesce under it, with per-message timestamps revealed on hover.
- Own messages get no special alignment or color. Messages that mention you get a subtle
  full-row background tint.
- Date separators between days; a subtle "unread messages" rule marking first-unread.
- Code blocks, tables, block math, and image galleries render naturally at full column
  width — a concrete benefit of the flat layout (no bubble-width gymnastics).
- Reactions render as a compact pill row under the message; click a pill to toggle, `+`
  opens the emoji picker.
- Hover controls (trailing the hovered message): react, reply-quote, more (edit, delete,
  copy, copy link, star, mark unread, read receipts).
- Edited/moved messages get a subtle "Edited" affordance (click → edit history later).
- Typing indicators: avatar + animated-ellipsis row at the transcript bottom.

### Content rendering

Server-rendered HTML → typed AST → native SwiftUI/AttributedString (no webviews). v1
renders: paragraphs, headings, bold/italic/strike/inline code, links (incl.
channel/topic/message links, which navigate in-app), lists, blockquotes, spoilers
(tap-to-reveal), code blocks with syntax-highlight colors, mentions (pills; own mentions
highlighted), unicode + custom emoji, inline images (thumbnail → Quick Look), video/audio
as preview cards, `<time>` as localized time chips. Math (KaTeX) shows styled TeX source in
v1, native rendering later. Unrecognized markup renders as a visible "unsupported content"
chip that opens the message in the web app — never silently dropped. Full dialect inventory
in PROTOCOL.md §7; pipeline in ARCHITECTURE.md §5.

### Compose

- Messages-style rounded field, bottom-aligned, grows to ~10 lines then scrolls.
- Return sends; ⇧Return inserts newline (both configurable).
- `@` mention autocomplete, `#` channel/topic-link autocomplete, `:emoji:` autocomplete —
  one popover component. Native emoji picker (⌃⌘Space) also works.
- Attachments: drag-drop, paste, or attach button → uploads via the API, inserts the
  markdown link; progress shown as a chip above the field.
- Sending is optimistic (local echo): the message appears immediately in a "sending" state,
  reconciled when the server event arrives; failures show retry affordance.
- Composing to a topic edits topic-name field only in the new-conversation flow; inside an
  existing conversation the destination is fixed (moving messages is a later feature).
- Drafts: field contents persist per-conversation locally in v1; server drafts sync later.

## 6. New conversation, channel browsing, search

- **⌘N New conversation**: Messages-style sheet with a `To:` field. Type a person → DM
  (add more people → group DM). Type `#` → channel autocomplete, then a topic field with
  existing-topic autocomplete (or a new topic name). One flow for everything.
- **Channel view**: scoped conversation list for one channel (topics by recency), with a
  subscribe/unsubscribe and notification-settings header. Reached via channel chips or the
  channel browser (⇧⌘K: searchable list of subscribed + browsable public channels).
- **Search (⌘K)**: global search field driving the server `search` narrow; results as a
  transient conversation-list scope. In-conversation find (⌘F) filters within the narrow.

## 7. macOS integration

- **Notifications**: local notifications generated from the event stream while the app
  runs (Zulip has no desktop push service — see PROTOCOL.md §6). Respect per-channel and
  realm notification settings from the store. Actions: inline reply, mark read. Clicking
  opens the conversation. Optional "menu bar mode" (keep syncing with window closed) later.
- **Dock badge**: count of unread DMs + mentions by default (configurable: all unreads / none).
- **Menu bar**: full command set — File (New conversation ⌘N), Edit, View (scopes ⌘1–⌘5),
  Go (next/prev conversation ⌥⌘↑↓, next unread ⌥⌘U, back ⌘[), Window, Help.
- **Keyboard-first**: arrow-key navigation in lists, ⌘K/⌘N/⌘F as above, Esc clears to
  sidebar. Full-keyboard-access compliant.
- **Accessibility**: VoiceOver labels for every row, message, and control from day one
  (messages read as "Sender, time, content, reactions"); Dynamic Type-equivalent (respect system
  text size); reduced-transparency and increased-contrast fallbacks.
- **Multi-account**: v1 is architecturally multi-account (see ARCHITECTURE.md) but ships
  single-account UI; account switcher (avatar menu in toolbar, ⌘1..9) in M3.
- **Settings (⌘,)**: General (send key, appearance), Notifications (badge policy, sounds,
  per-realm), Accounts (add/remove, realm info).

## 8. Milestones

**M0 — Foundations (no UI beyond a debug shell).** SwiftPM workspace; `ZulipAPI` package
(connection, auth incl. web-auth flow, typed routes, event decoding); `ZulipModel` package
(GlobalStore/PerAccountStore, UpdateMachine register→poll→recover loop, event application
for messages/users/channels/unreads); Keychain storage; test fakes for every layer.
Exit criterion: a harness target that logs in, syncs live events, and prints them, with the
store surviving queue expiry and event-application faults via snapshot rebuild.

**M1 — Read-only client.** Main window, unified sidebar (all scopes), transcript with the
v1 content-node set, history pagination with stable scroll position, unread marking as you
read, channel view, conversation search-free navigation. Exit criterion: daily-drivable for
reading chat.zulip.org.

**M2 — Full messaging.** Compose with autocomplete + local echo; reactions; edit/delete
own messages; typing indicators (send + display); presence; starring; file upload;
new-conversation flow. Exit criterion: daily-drivable as a primary client.

**M3 — Mac polish.** Notifications with inline reply; dock badge; global search (⌘K);
settings window; multi-account UI; channel browser with subscribe; muted-content UX;
Quick Look attachments; sounds. Exit criterion: shippable public beta (Developer ID).

**M4 — Depth.** Offline cache (persisted store snapshot + message cache); native math
rendering; polls; link previews; message moving; scheduled messages; server draft sync;
read receipts; edit history viewer.

Cross-cutting every milestone: accessibility, keyboard access, and tests land with each
feature, not as a later pass.

## 9. Open questions

1. **Name & identity** — needs a distinct name/icon that doesn't claim official status
   (Zulip's trademark guidance applies); "Zulip for macOS" is a placeholder.
2. **Menu-bar background mode** — valuable (notifications with the window closed) but has
   energy/App Store implications; revisit at M3.
3. **Mac App Store** — sandbox is compatible, but web-auth flow and Sparkle-vs-MAS
   updating differ; decide at M3.
