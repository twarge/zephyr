import SwiftUI

/// The app manual: Help → Zephyr Help (⌘?) on macOS; the Help tab of
/// Settings on iOS (which has no system Help menu).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Zephyr Help")
                    .font(.title.weight(.semibold))

                helpSection("Servers and Accounts", bullets: [
                    "Add accounts in Settings → Accounts. Every signed-in server stays connected — notifications and unread badges cover all of them.",
                    "Each window shows one server. ⌘1–⌘9 (ordered as in Settings → Accounts) or the server menu in the sidebar toolbar switch the front window; other windows keep what they're showing.",
                    "Sign out of the current server from the sidebar's server menu.",
                ])

                helpSection("Windows and Navigation", bullets: [
                    "Open Quickly (⌘⇧O) jumps to any channel or view — start typing, or pick from the special views and your recent channels.",
                    "New Window (⌘⇧N) opens another window; double-clicking a sidebar item opens that conversation in its own window.",
                    "In a topic, the window title is a menu: click it to reach the channel's full feed or its topic list.",
                    "In a channel's feed, the current topic pins to the top; click any topic header to focus that topic.",
                    "Narrow windows tuck the sidebar away automatically; widen the window to bring it back.",
                ])

                keyboardSection

                helpSection("Messages and Composing", bullets: [
                    "Hover a message for the react and star controls; right-click for Reply Quoting Message, Copy Message Reference, Move, Edit, and Delete.",
                    "Select an image and press Space for Quick Look; the arrow keys step through every image in the view.",
                    "Drag files anywhere into a conversation, or paste an image (⌘V), to upload — Send waits until uploads finish.",
                    "The chevron beside the message field opens long-form compose: a resizable editor with a rendered preview (the eye); there, Return makes a new line and ⇧Return sends.",
                    "The topic field suggests the channel's existing topics as you type; free text starts a new topic.",
                    "Drafts save per conversation when you navigate away, and sync with the server.",
                ])

                helpSection("Offline and History", bullets: [
                    "Messages you've seen are kept in a local archive: scroll back and search even while offline; sends queue and deliver on reconnect.",
                    "Settings → General controls how long the archive keeps history (starred messages are always kept). The server's history is never affected.",
                ])
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 700)
        #endif
    }

    /// App-level shortcuts that live in menus rather than the in-view
    /// keymap.
    private static let appShortcuts: [(String, String)] = [
        ("⌘⇧O", "Open Quickly — channel or view"),
        ("⌘[  ⌘]", "Back / forward"),
        ("⌥⌘1…6", "Go to Recent, Combined, Mentions, Starred, Drafts, Outbox"),
        ("⌘F", "Search"),
        ("⌘R", "Reply to the selected message"),
        ("⌥⌘R", "Reload the current view"),
        ("⌘⇧N", "New window"),
        ("⌘N", "New conversation"),
        ("⌘E", "Edit the selected message"),
        ("⌘⇧C", "Copy message reference"),
        ("⌘⇧K", "Mark conversation as read"),
        ("⌘B  ⌘I  ⌘K", "Bold / italic / link while composing"),
        ("⌘⇧X  ⌘⇧M  ⌘⇧9", "Strikethrough / code / quote"),
        ("⌘=  ⌘−", "Bigger / smaller text"),
        ("⌘/  or  ?", "Show the shortcuts sheet"),
    ]

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Navigation")
                .font(.title3.weight(.semibold))
            Text(
                "Zephyr uses the Zulip web app's keymap. The single-key shortcuts work whenever no text field has focus — on the Mac, and on iPhone and iPad with a hardware keyboard.")
                .foregroundStyle(.secondary)
            ForEach(ShortcutsHelpView.sections, id: \.0) { title, rows in
                shortcutTable(title, rows: rows)
            }
            shortcutTable("App-wide", rows: Self.appShortcuts)
        }
    }

    private func shortcutTable(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.1) { keys, action in
                HStack(alignment: .firstTextBaseline) {
                    Text(keys)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(action)
                        .font(.callout)
                }
            }
        }
    }

    private func helpSection(_ title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(bullet)
                }
                .font(.callout)
            }
        }
    }
}
