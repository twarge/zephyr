import SwiftUI
import ZulipModel

/// Searchable emoji grid for adding a reaction: unicode emoji from the
/// server catalog plus realm custom emoji.
struct EmojiPickerView: View {
    let store: PerAccountStore
    let onPick: (EmojiEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [EmojiEntry] {
        let entries = store.emojiEntries
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty {
            return Array(entries.prefix(240))
        }
        let prefixMatches = entries.filter { $0.name.hasPrefix(trimmed) }
        let containsMatches = entries.filter {
            !$0.name.hasPrefix(trimmed) && $0.name.contains(trimmed)
        }
        return Array((prefixMatches + containsMatches).prefix(240))
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8),
                    spacing: 4
                ) {
                    ForEach(filtered) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            Group {
                                if let character = entry.character {
                                    Text(character).font(.system(size: 20))
                                } else if let src = entry.realmSrc,
                                          let image = EmojiImageLoader.shared.image(
                                            src: src, connection: store.connection) {
                                    Image(nsImage: image)
                                } else {
                                    Image(systemName: "face.smiling")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(":\(entry.name):")
                    }
                }
            }
            if store.emojiEntries.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 300, height: 320)
        .onAppear {
            store.loadEmojiCatalogIfNeeded()
            searchFocused = true
        }
    }
}
