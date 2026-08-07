# Remaining extension targets (need Xcode's target UI)

Two adoptions from the platform-integration pass require new app-extension
targets. Creating targets in this synchronized-group project is a
File → New → Target operation in Xcode (~5 minutes each); hand-editing
project.pbxproj for embedded extension targets is not worth the corruption
risk. Everything in-app that they depend on already exists.

Shared prerequisite — App Group
- Add the "App Groups" capability to the app and each extension target,
  with group id `group.com.twarge.zephyr`.
- The group container is the data channel both features use.

## 1. Share extension ("send to Zephyr from anywhere")

Architecture (deliberately thin — the extension never talks to Zulip):
1. Extension target (one per platform, or macOS first): a small UI that
   collects the shared attachments/text and writes them into an "inbox"
   directory in the group container, then completes.
2. App side: on activation, check the inbox; if entries exist, open the
   New Conversation sheet with the files pre-attached to the upload
   pipeline (ComposeBar's upload path handles the rest).

The app-side inbox consumer and compose-bar attachment seeding are the
only new app code; the extension itself is ~100 lines.

## 2. Unreads widget (WidgetKit)

Architecture:
1. App side: write a compact JSON summary (per-account unread/mention
   counts, top conversations) into the group container whenever the badge
   count changes (MainSplitView already recomputes it there).
2. Widget target: a timeline provider that reads the summary and renders
   small/medium unread views; deep-links open conversations via the
   existing `zulip://`-style internal routing, and OpenConversationIntent
   (already shipped) can make rows interactive.

## Also gated on Xcode capability UI

- Communication-notification styling: enable the "Communication
  Notifications" capability on the app target (profile-gated entitlement).
  The INSendMessageIntent donation in NotificationManager is already live
  and takes effect the moment the entitlement exists.
