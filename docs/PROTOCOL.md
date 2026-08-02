# Protocol Notes — Zulip API as this client uses it

Condensed from the official docs (https://zulip.com/api/), the server OpenAPI spec, and
zulip-flutter's source (verified 2026-08-01). This is the project's working reference;
each area cites its doc page. Items marked ⚠ were not fully verified — re-check before
implementing against them.

**Server floor: Zulip Server 9.0, feature level (FL) 277** — same as zulip-flutter's
minimum. Everything below assumes ≥277, so modern names (`channel`, `dm`, `direct`) are
used unconditionally; features above 277 note their FL gate.

## 1. Auth (api/fetch-api-key, api/get-server-settings)

- All REST calls: HTTP Basic auth, `email:api_key`, base path `https://<realm>/api/v1/`.
  ⚠ The username must be the user's **delivery email** (what they log in with) —
  verified in server source (`access_user_by_api_key`): a mismatch raises "Invalid
  API key" even when the key is correct. On realms that hide addresses, user objects
  (including `/users/me`) carry a `user{id}@{host}` alias in `email` — never use that
  for auth. `fetch_api_key`'s `email` response field is the canonical auth email.
- **Realm discovery**: `GET /server_settings` (unauthenticated) → `zulip_version`,
  `zulip_feature_level`, `realm_url`, `realm_name`, `realm_icon`, `email_auth_enabled`,
  `external_authentication_methods: [{name, display_name, display_icon, login_url, …}]`.
  Drives the login screen and the server-floor check.
- **Password login**: `POST /fetch_api_key` (`username`, `password`) → `api_key`,
  `user_id`. Only works where email/LDAP auth backends are enabled.
- **Web/SSO login (mobile flow)** — server-source-verified, not on the docs site:
  1. Generate OTP: 64 random hex chars (32 bytes).
  2. Open `<login_url>?mobile_flow_otp=<otp>` in `ASWebAuthenticationSession`
     (callback scheme `zulip`).
  3. Server redirects to
     `zulip://login?otp_encrypted_api_key=<hex>&email=…&user_id=…&realm=…`.
  4. `api_key = ascii(hex(otp_encrypted_api_key) XOR hex(otp))`.
  - (The Electron app's `desktop_flow_otp` yields only a 15-second browser-session token,
    not an API key — not useful to us.)

## 2. Event system (api/register-queue, api/get-events)

- **`POST /register`** with: `apply_markdown: true`, `client_gravatar: false`,
  `idle_queue_timeout` (FL 481+; seconds, max 7 days — pass something long; default is
  only 10 min), and `client_capabilities` (start from zulip-flutter's set, all true):
  `notification_settings_null`, `bulk_message_deletion`,
  `user_avatar_url_field_optional`, `stream_typing_notifications`,
  `user_settings_object`, `include_deactivated_groups`, `empty_topic_name` (FL 334),
  `individual_emoji_changes`.
  Prototype with unfiltered `event_types`; before shipping, filter `event_types` /
  `fetch_event_types` (docs: "often saves 90% of bandwidth").
- Register returns: `queue_id`, `last_event_id`, `zulip_feature_level`,
  `event_queue_longpoll_timeout_seconds` (use as the HTTP timeout for /events),
  `idle_queue_timeout_secs`, plus initial state: `realm_users`, `streams`,
  `subscriptions`, `unread_msgs`, `starred_messages`, `presences`,
  `recent_private_conversations`, `realm_emoji`, `server_emoji_data_url`, `user_settings`,
  `user_topics`, `muted_users`, `drafts`, `scheduled_messages`, `alert_words`, and realm
  limits (`max_message_length`, `max_topic_length`, `max_file_upload_size_mib`,
  `server_typing_*`, `server_presence_*`).
- **`GET /events`** long-poll with `queue_id` + `last_event_id` (acking lets the server
  GC); events have monotonic non-consecutive `id` and `type`(+`op`). `heartbeat` events
  arrive periodically (⚠ cadence prose is inconsistent; trust the longpoll-timeout value).
- **Queue death**: HTTP 400 `code: BAD_EVENT_QUEUE_ID` (after `idle_queue_timeout` without
  polling). No replay exists — re-register and rebuild all state.
- `DELETE /events` with `queue_id` on sign-out.
- **`unread_msgs` shape**: `{count, pms: [{other_user_id, unread_message_ids}], streams:
  [{stream_id, topic, unread_message_ids}], huddles: [{user_ids_string, unread_message_ids}],
  mentions, old_unreads_missing}` — covers the ~50k most recent unreads; warn on
  `old_unreads_missing`; maintain incrementally from `message` + `update_message_flags`
  events.

## 3. Messages (api/get-messages, api/send-message, api/construct-narrow)

- **Fetch**: `GET /messages` — `anchor` (`newest`|`oldest`|`first_unread`|id),
  `num_before`/`num_after` (≤1000 per batch recommended), `narrow`, `include_anchor`
  (FL 155), `message_ids[]` (FL 300), `anchor_date` (FL 445). Response includes
  `found_oldest`/`found_newest`/`history_limited`. Message fields to note:
  `subject` = topic (legacy name), `display_recipient` (channel name or DM user array),
  `flags`, `reactions`, `last_edit_timestamp`, `edit_history`.
- **Narrow operators** (JSON `[{operator, operand, negated?}]`): `channel` (operand:
  channel **id**), `topic`, `dm` (operand: user-id array), `dm-including`, `sender`,
  `search`, `id`, `near`, `with`, `is` (`unread|mentioned|starred|followed|dm|resolved`),
  `has` (`link|image|attachment|reaction`). All modern names are < FL 277 — safe
  unconditionally.
- **Send**: `POST /messages` — `type: "direct"` (`to`: user-id array) or `"channel"`
  (`to`: channel id, `topic`). Local echo: pass `queue_id` + `local_id`; the `message`
  event echoes `local_message_id`. `read_by_sender: true` (FL 236).
- **Edit/move**: `PATCH /messages/{id}` — `content`, or `topic`/`stream_id` +
  `propagate_mode` (`change_one|change_later|change_all`); `prev_content_sha256` for
  optimistic concurrency. **Delete**: `DELETE /messages/{id}`. Both are permission-gated
  by realm/channel settings from the snapshot.
- **Flags**: `POST /messages/flags` (`messages[]`, `op: add|remove`,
  `flag: read|starred|collapsed`). Ranged: `POST /messages/flags/narrow` (FL 155) —
  narrow + anchor range; the canonical mark-as-read mechanism (the old
  `mark_*_as_read` endpoints are deprecated). Read receipts:
  `GET /messages/{id}/read_receipts` (FL 137).

## 4. Presence, typing, reactions, emoji, uploads, misc

- **Typing** (api/set-typing-status): `POST /typing` — `op: start|stop`; `type: "direct"`
  (`to`: user ids) or `"channel"` (`stream_id` + `topic`). Timing constants come from the
  register payload (`server_typing_started_wait_period_milliseconds`, `…stopped_wait…`,
  `…started_expiry…`): send start every *wait* ms while typing, stop on idle, expire
  displayed indicators after *expiry* ms.
- **Presence** (api/update-presence): `POST /users/me/presence` every
  `server_presence_ping_interval_seconds` with `status: active|idle`, `new_user_input`,
  and modern-protocol `last_update_id` (start −1; FL 263+); offline threshold
  `server_presence_offline_threshold_seconds`.
- **Reactions**: `POST`/`DELETE /messages/{id}/reactions` — send `emoji_name` +
  `emoji_code` + `reaction_type` (`unicode_emoji` = dash-joined hex codepoints,
  `realm_emoji` = custom-emoji id, `zulip_extra_emoji`).
- **Emoji data**: custom set from `realm_emoji` (snapshot + events); unicode
  name↔codepoint map downloaded from `server_emoji_data_url`
  (`{code_to_names}`, canonical name first) — cacheable, changes only on server upgrade.
- **Uploads** (api/upload-file): `POST /user_uploads` multipart → `{url, filename}`;
  reference as `[filename](url)` in message content; limit `max_file_upload_size_mib`;
  tus resumable endpoint `/api/v1/tus` for large files. `/user_uploads/*` GETs require
  auth; for handing to Quick Look/browser use the temporary-public-URL endpoint
  `GET /user_uploads/{realm_id_str}/{filename}` → short-lived public URL.
- **Topics**: `GET /users/me/{stream_id}/topics` → `[{name, max_id}]` recency-sorted.
- **Topic visibility**: `POST /user_topics` (FL 170) — `visibility_policy`:
  0 none / 1 muted / 2 unmuted / 3 followed (FL 219); state in `user_topics`.
- **Muted users**: `POST/DELETE /users/me/muted_users/{id}`; clients are expected to hide
  their 1:1 DMs and collapse them elsewhere.
- **Drafts / scheduled messages**: full CRUD APIs synced via events (note: drafts API
  still uses legacy `"stream"`/`"private"` type strings). Deferred to M4.
- **Avatars**: with `user_avatar_url_field_optional`, `avatar_url` may be omitted —
  fetch `GET /avatar/{user_id}` (redirects to image).

## 5. Feature-level gates we actually care about (api/changelog)

| FL | Server | Feature |
|---|---|---|
| 277 | 9.0 | **our floor** — modern narrow/type names all predate this |
| 300 | 9.0? | `message_ids[]` on GET /messages |
| 334 | 10.0 | `empty_topic_name` capability; empty-string topics |
| 445 | 12.0 | `anchor_date` fetching |
| 481 | 12.0 | `idle_queue_timeout` on /register |
| 483 | 12.0 | E2EE push registration (mobile-only; not used) |

Current head was FL ~506 (13.0-dev) at research time. Gate with
`connection.featureLevel >= N`; treat `zulip_merge_base` as the real level on forks.

## 6. Notifications reality-check

**There is no desktop push mechanism** — verified by absence in the OpenAPI spec. The push
bouncer + APNs/FCM registration endpoints are mobile-app-only (and ⚠ the Cloud bouncer
presumably only holds credentials for Zulip's own app ids). Desktop-style clients keep an
event queue open and post local notifications from `message` events. Consequence: no
notifications while our app isn't running; mitigations in SPEC §7 / ARCHITECTURE §10.

## 7. Rendered-HTML dialect (api/message-formatting)

With `apply_markdown: true`, `content` is server-rendered HTML (`content_type:
"text/html"`). Known constructs (parser whitelist inventory — anything else →
`.unimplemented`):

- **Mentions**: `<span class="user-mention" data-user-id="31">@Name</span>`; variants:
  `user-mention silent`, `user-group-mention` (+`data-user-group-id`), wildcard
  `channel-wildcard-mention` (`data-user-id="*"`), `<span class="topic-mention">`.
- **Emoji**: unicode `<span class="emoji emoji-263a" title="…">:name:</span>` (codepoints
  in the class); custom `<img class="emoji" src="/user_avatars/…">`.
- **Internal links**: `<a class="stream" data-stream-id="9">`, `class="stream-topic"`,
  `class="message-link"` — navigate in-app.
- **Code blocks**: `div.codehilite` with `data-code-language`, Pygments token spans.
- **Media**: `div.message_inline_image` → `<a href="/user_uploads/…"><img
  src="/user_uploads/thumbnail/…" data-original-dimensions="WxH">…`; video variant
  `message_inline_video`; `<audio>`; `image-loading-placeholder` during thumbnailing;
  `data-transcoded-image` for HEIC/TIFF.
- **Math**: KaTeX span markup, inline + block (⚠ exact class structure not captured —
  capture fixtures from a live server before writing this parser rule; zulip-flutter's
  `lib/model/katex.dart` is the reference, incl. falling back to TeX source).
- **Spoilers**: `div.spoiler-block` containing `div.spoiler-header` + `div.spoiler-content`
  (per zulip-flutter's parser; ⚠ confirm against live fixtures).
- **Misc**: `<time>` with ISO 8601 (render localized), headings h1–h6, ordered lists with
  `start`, blockquotes, tables with per-column alignment, link previews
  (`div.message_embed`), polls arrive as structured *submessages* (not HTML).
- Quirks zulip-flutter handles that we will too: implicit paragraphs inside `<li>`,
  KaTeX wrapped in `<p>`, stray `<br>\n`, consecutive images grouped into galleries.

## 8. Etiquette

- Rate limits: default 200 req/min/user; honor `X-RateLimit-*` headers and 429
  `retry-after` (never hardcode limits).
- `User-Agent: ZulipForMac/<version> (macOS <os-version>)` — the server parses this into
  its `Client` analytics and the `read_by_sender` heuristic.
- Exponential backoff on all reconnects; `dont_block: true` on recovery polls; delete
  event queues on sign-out.
