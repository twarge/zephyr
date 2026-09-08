# Home view study

Status: implemented September 8, 2026. The design study below records the rationale; the implementation notes describe the current code. The earlier visual concept uses illustrative conversations, not live account data.

## Implementation notes

Home is the first row of the sidebar's Views section, with Go → Home (⌘⌥0) and Open Quickly support. It collapses and filters with the rest of that section, unlike the standalone row the proposal below describes. Existing saved destinations are preserved. Summary rows open the existing transcript at the pending mention or first unread message, using its normal reply/react controls.

`HomeActivityStore` maintains account-scoped activity independently of unread flags, and `TopicActivityIndex` applies red → blue → green precedence. It uses confirmed server messages/reactions, retains pending mentions across relaunch, handles moves/deletes, and prevents stale fetches or model output from restoring removed content. Updates rebuild only affected topics. Edited mentions whose reaction timing cannot be established say “Check response to edited mention.”

`TopicSummaryService` uses Apple's on-device model with a fresh, structured session per generation. It queues one generation at a time across windows, shares duplicate requests, cancels abandoned work, limits input, and caches up to 100 summaries per account using source and version fingerprints. Single messages and unavailable/failed generations use labelled previews. iOS 18–25 retain the Home list without model generation.

Discovery is intentionally bounded: up to 1,000 recent messages, up to 1,000 mentions within the initial 30-day lookback, 50 recent messages per visible topic, a separate latest-self-reply query, and at most 60 older mention-target checks per pass. Per-topic checks run four at a time rather than one after another, and cover the rows actually on screen — a sidebar filter can surface a row from past the initial 30. Home initially displays 30 topics with more available. Partial history is labelled; it is not a guarantee of complete historical coverage. A later message in the same topic counts as participation, not proof that it semantically answers a question. Broadcast/group mentions do not require an individual response.

Validation includes package tests for status precedence, persistence, edits/moves/deletes, cross-device responses, incomplete history, cancellation, request bounds, and a deletion racing a fetch; macOS and iOS Simulator builds; and a real on-device generation with fictional messages. The device model was available and produced a two-sentence summary in about 3.2 seconds. This smoke check is not a broad accuracy or energy benchmark.

## Proposed experience

Add **Home** as the first navigation item in the sidebar, above the collapsible Views section. Keep it visible when sections collapse. The existing account and search toolbar stays above navigation. Home belongs to the selected account, consistent with the rest of Zephyr.

Show a quiet list of channel/topic pairs, with a two-sentence activity summary under each topic, taking about 2–3 lines. Each row has a small leading status indicator, channel and topic names, the time of the latest message, and a secondary line such as “3 unseen,” “Mention awaiting response,” or “You reacted.” Clicking anywhere on a summary row navigates directly to the existing topic transcript for reply/react. Home adds no intermediate detail screen, separate composer, or reaction interface. Reading a summary does not mark its source messages read.

Use real channel/topic names; the model writes only the summary. Focus its text on what changed, decisions made, unresolved questions, and concrete next steps actually stated in the conversation. Keep names, dates, negation, and uncertainty accurate. Do not infer an agreement from an emoji or turn a suggestion into a decision.

Proposed defaults:

- Show subscribed channels with activity in the past seven days, newest topic activity first. This window is a starting product choice, not an existing app rule.
- Show 30 topics initially, with more available on demand. Known unanswered mentions stay eligible outside the seven-day window; list pagination must not discard their state. Sort by message activity, never summary generation time.
- Respect explicit topic mutes. In a muted channel, include explicitly followed or unmuted topics. Do not resurrect conversations from channels the user cannot access.
- Start with channel topics. Direct messages already have their own navigation and are outside this request.
- Keep the saved destination on existing accounts. Use Home when an account has no saved destination; sidebar position does not require resetting everyone's navigation.
- At narrow widths, wrap channel/topic labels and cap the summary at three lines. Open the topic for full context. With large accessibility text, allow additional lines instead of clipping essential information.

## Indicator rules

Unread activity and participation are independent facts. Derive both from message state; never ask the language model to decide the dot color.

| Priority | Leading indicator | Condition | Opening the row |
| --- | --- | --- | --- |
| 1 | Red dot | At least one known personal @mention has no qualifying reply or reaction | Land on the oldest unresolved mention |
| 2 | Blue dot | No unresolved mention, but the topic has unseen messages | Land at the first unread message |
| 3 | Green check | No unresolved mention or unseen messages, and the user replied or reacted in the activity being shown | Open the topic normally |
| 4 | Empty indicator space | Read activity with no qualifying participation | Open the topic normally |

A reply or reaction can coexist with new messages. In that case, blue wins, and secondary text can retain “You replied” or “You reacted.” Red similarly wins over blue; an unseen count can still appear. A check means participation, not that all issues in the conversation are resolved. Reading alone never produces a check.

Each indicator needs a VoiceOver label and a text equivalent in row metadata. Blue and red dots must not be distinguishable only by color. Reserve the same leading space for all four states to avoid shifting titles.

### What counts as a response

For a first version, define a response mechanically and explain it in help text:

1. A **confirmed message sent by the current user in the same topic after the mention** acknowledges earlier mentions in that topic. This is a participation heuristic; Zulip topics do not supply a reliable semantic answer relationship. An unrelated later message may therefore count as a response.
2. A **current, confirmed reaction by the user on the mentioning message itself** acknowledges that particular mention. Reacting elsewhere in the topic does not clear it. Multiple mentions are evaluated individually.
3. A message drafted, queued, or failed in the outbox is not a confirmed reply. A queued offline reaction may show a pending label, but should not clear red until confirmed.
4. A new mention after a reply turns the topic red again. Removing the only qualifying reaction or deleting the only qualifying reply recalculates the state.
5. Merely opening the transcript, marking it read, or reacting before a later mention does not acknowledge that later mention.

Treat personal, non-silent mentions of the current user as red candidates initially. Exclude self-authored mentions. Broadcast and group mentions remain normal unread activity in this proposal; supporting them as requests for an individual response should be an explicit later product choice.

An edit can add a mention to an old message. Compare response evidence to the mention-bearing revision, not only the message's original ID. Reuse the content parser's typed mention targets and `silent` property, together with server flags. If it is unclear whether an old reaction predates an edit adding the mention, do not infer acknowledgement from reaction presence alone. Preserve an uncertainty/freshness state until reconciled.

Reactions contain a user ID but no reaction timestamp. They can establish that a user reacted to a particular message; they cannot establish a global “last time the user reacted to this topic.” A check for general participation should be scoped to messages in the displayed activity window, not an arbitrary historic reaction.

## Fit with the existing code

| Existing source | What Home can reuse | Required addition or caution |
| --- | --- | --- |
| `Zephyr/Views/SidebarView.swift` | Native sidebar, view row builder, selection, detaching | Add a Home row at the top of the Views section, sharing that section's collapse and filtering behavior |
| `Zephyr/Views/MainSplitView.swift` | Codable `Destination`, detail routing, navigation history and message anchors | Add `.home`, route to `HomeView`, and audit destination-dependent search/toolbars and shortcuts |
| `Zephyr/AppStateStore.swift` | Per-account saved selection | Preserve existing selections and round-trip the new destination |
| `Zephyr/Views/RecentConversationsView.swift` | Channel/topic labels, row navigation, recency source | Home should have a separate summary row and model; avoid copying the whole-message-map scan into every view render |
| `Packages/ZulipKit/Sources/ZulipModel/ConversationList.swift` | Recent topic candidates and latest message IDs | It only stores the latest snippet, not a conversation transcript or completeness information |
| `Packages/ZulipKit/Sources/ZulipModel/Unreads.swift` | Server unread IDs by conversation | `mentionIds` is an unread set and is cleared on read; it cannot track unanswered mentions |
| `Packages/ZulipKit/Sources/ZulipModel/PerAccountStore.swift` | Canonical messages, send confirmations, reactions, flags, sync lifecycle and persistence hooks | Publish targeted activity invalidation; retain an independent mention/acknowledgement index |
| `Packages/ZulipKit/Sources/ZulipModel/MessageDatabase.swift` | Per-account SQLite messages and indexed topic queries | Add bounded activity reads, coverage bookkeeping, and a versioned summary cache |
| `Packages/ZulipKit/Sources/ZulipContent/ContentParser.swift` and `ContentNodes.swift` | Typed mentions and plain-text extraction | Prepare bounded text off the main actor; preserve speaker/message boundaries and useful code/attachment labels |

Before this change, the app had no Foundation Models integration. The project targets macOS 26 and iOS 18, so iOS retains a non-model path on older systems. The implementation uses the macOS/iOS 26 API surface supported by the installed Xcode 27 beta SDK.

Two existing behaviors need particular care:

- `ConversationList` is updated by seeds and new-message events. In the current event handler, edits, deletes, and topic moves update messages without rebuilding that conversation index. Home cannot assume all existing recency metadata follows those changes correctly. It needs targeted repair or its own derived index, plus canonical topic keys for case variants, empty topics, moves, and merges.
- Reaction events for messages absent from memory are currently ignored, and fetch reconciliation generally keeps the live copy's reactions and flags. An unanswered-mention tracker must hydrate unresolved targets and reconcile missed changes with event ordering; otherwise responses from another client can leave a false red dot. Do not solve this by blindly overwriting canonical messages with a potentially older fetch.

## Obtaining enough history

The Recent view calls `seedConversations(count: 200)`: that is a combined feed sample of 200 messages, not 200 messages per topic or a complete seven-day history. The offline cache also contains only previously fetched history. Neither proves a thread has no reply or unseen mention.

Build Home from bounded, per-topic message slices. Populate candidates from the existing conversation list, then page recent feed history within the chosen time window and budget. For visible topics, load the latest slice plus relevant unread/mention context, first from SQLite and then from the server as needed. Deduplicate requests across windows.

Bootstrap personal mention candidates using the existing mentions narrow, including read messages, and filter the results to the personal-mention policy. Page within a documented initial lookback (proposed: 30 days) and preserve already discovered unresolved targets beyond that lookback. Check for qualifying responses after each candidate. Track whether that interval is complete through a known latest message. Store rebuilds and reconnects must revalidate the index.

An older undiscovered mention is not guaranteed to appear in v1. An incomplete or server-limited interval must never be presented as “all caught up.” Use a brief “Checking recent activity…” or “Some history unavailable” state and retain verified pending evidence. Offer older-history loading if comprehensive historical coverage is required. Known unanswered mentions should remain visible when possible, even if their summary has to fall back to an excerpt.

## On-device summary design

Apple identifies summarization as a suitable task for the on-device Foundation Models framework. It provides structured Swift output, runtime model availability, and offline inference on eligible devices. Availability depends on Apple Intelligence and model readiness, not only the OS version. [Apple's framework overview](https://developer.apple.com/videos/play/wwdc2025/286/)

Use an app-layer `TopicSummaryService` wrapping `SystemLanguageModel.default` and a fresh `LanguageModelSession` per topic generation. Keep Foundation Models out of the portable ZulipModel package. Inject a small summarizer interface so model-independent activity behavior can be tested.

Pipeline:

1. Read a consistent, bounded topic snapshot and its revision from the account store/database.
2. Convert rendered content into plain text on a background executor. Include message IDs, speaker names and timestamps; separate quotes from new statements. Cap long code blocks and attachments, retain useful labels, and do not fetch linked documents or media to summarize them.
3. Give the model static summarization instructions and put conversation text only in the source-data prompt. Treat messages as untrusted text. Give this summarization session no action tools.
4. Generate a small structured result: supporting source message IDs and a short summary. Aim for two sentences, approximately 35–55 English words; line count is a view/layout decision and output length needs post-validation. Preserve the conversation's language where supported.
5. Validate IDs against the supplied source, check length and empty output, then publish only if the account, topic, and source revision still match. Valid IDs and structured output do not prove the text is factually correct.
6. Cache the result with the source message IDs/content digest, activity window, prompt/schema version, output language, generation time, and model/OS version information where available. Recompute from source text instead of repeatedly summarizing a previous summary.

The on-device model has a roughly 4K context budget in the documented baseline. Instructions, source text, schema and output share it. Use conservative input limits, leave output headroom, and shrink/retry once on context overflow. Newer SDKs expose context size; availability-gate that API rather than assuming it exists on OS 26. Prefer an honestly labelled “Recent messages” summary of a bounded slice for v1; summarizing an entire busy week via multiple chunks needs separate quality and performance evaluation. [Apple's context-limit documentation](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/exceededcontextwindowsize(_:)), [Apple's model comparison](https://developer.apple.com/videos/play/wwdc2026/319/)

Start with one generation at a time across account windows, prioritizing visible rows and then unanswered mentions. Deduplicate equivalent work, debounce message bursts, and cancel obsolete work on account changes, store replacement or navigation. Render cached summaries immediately. Replace completed summaries without reordering the list. Read-state changes update indicators immediately and do not rerun text generation; reaction changes require regeneration only if reactions were included as summary evidence.

Keep inference on-device, with no cloud fallback. Normal Zulip synchronization still uses the account's server. Partition cached text by account and remove it on account removal/cache clearing. Edits and deletes invalidate affected summaries immediately so removed content does not remain on Home. Topic moves, merges and access changes invalidate both affected identities. Store replacement requires revalidation before treating a cache entry as current.

### Unavailable and incomplete states

Home should remain useful on older iOS versions, ineligible hardware, with Apple Intelligence off, while the model downloads, offline, or after a generation refusal/error. Keep the same rows and deterministic indicators. Show a latest-message preview explicitly labelled “Latest message,” plus a concise account-level explanation when appropriate. Cached summaries may appear with their freshness labelled; removed or no-longer-accessible content must not.

Do not show a blank Home, an endless spinner, or invented summary text. Handle unsupported languages and overly large input as ordinary per-row fallbacks. A complete source history and a successfully generated summary are separate states.

## Implementation sequence and validation

1. **Activity state:** add topic aggregation, mention coverage/acknowledgement persistence, canonical identity handling and targeted invalidation. Verify read-but-unanswered mentions, multiple mentions, new mentions after responses, unrelated reactions, reaction removal, deleted replies, edited mentions, topic moves/merges, missing cached messages, offline actions and cross-device reconciliation.
2. **Home UI:** add destination/sidebar/routing and preview-backed rows. Verify saved selections, two-account isolation, keyboard navigation, message anchors, no read-marking from Home, sidebar position, large text and light/dark appearance.
3. **Summary service:** integrate the availability-gated Apple provider and versioned cache. Verify context overflow, empty/refused output, unsupported languages, stale results racing new messages, edits/deletes and cancellation. Use a fake provider for deterministic tests.
4. **Device evaluation:** run a synthetic or consented test corpus with decisions, reversals, negation, technical terms, multiple speakers, code and prompt-injection text. Measure factual omissions/errors, first-visible-summary latency, warm-cache behavior, sustained CPU/energy use and scrolling responsiveness on the lowest supported Apple Intelligence hardware.

The implementation and validation completed so far are recorded at the top. Broader corpus accuracy and energy evaluation remain useful follow-up work; a single successful generation cannot establish those properties.
