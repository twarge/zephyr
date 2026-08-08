# Extension targets

Both app extensions are declared in project.yml (regenerate with
`xcodegen generate`) and share the `group.com.twarge.zephyr` App Group.

## Share extension (ZephyrShare)

Deliberately thin — it never talks to Zulip:

1. The extension copies shared attachments into an "inbox" directory in
   the group container (`Shared/ShareInbox.swift`), joins any shared
   text/URLs into a manifest, shows a brief confirmation, and completes.
   On macOS it also nudges the app awake via the `zephyr://` scheme.
2. On activation the app's key window finds the inbox non-empty and
   offers a destination picker (`SharePickerSheet`, backed by Open
   Quickly's search). Picking navigates there; the compose bar seeds
   itself — uploads start through the normal pipeline, shared text lands
   in the draft — and the inbox entry is cleared.

## Unreads widget (ZephyrWidgets)

1. The app writes an unread digest (totals, mentions, top conversations
   across all servers) into the group container whenever the badge count
   changes, then reloads the widget timeline (`WidgetSummaryWriter`).
2. The widget (`Extensions/Widgets`) renders small/medium views from
   that digest; the timeline schedule is only a fallback.

## Provisioning notes

- Each extension bundle id needed its App ID minted once via
  `xcodebuild -allowProvisioningUpdates`; plain builds work after that.
- Communication-notification styling required enabling the capability on
  the app target once in Xcode; the entitlement lives in the committed
  entitlements files and survives regeneration.
