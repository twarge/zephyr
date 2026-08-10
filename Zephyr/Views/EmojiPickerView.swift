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

    // Pointer-sized cells on macOS; 44pt touch cells and a roomier
    // popover on iOS.
    #if os(macOS)
    private static let cellSize: CGFloat = 30
    private static let glyphSize: CGFloat = 20
    private static let pickerSize = CGSize(width: 300, height: 320)
    #else
    private static let cellSize: CGFloat = 44
    private static let glyphSize: CGFloat = 28
    private static let pickerSize = CGSize(width: 380, height: 480)
    #endif

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
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.4), in: .capsule)
                .focused($searchFocused)
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cellSize), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(filtered) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            Group {
                                if let character = entry.character {
                                    Text(character).font(.system(size: Self.glyphSize))
                                } else if let src = entry.realmSrc,
                                          let image = EmojiImageLoader.shared.image(
                                            src: src, connection: store.connection) {
                                    Image(platform: image)
                                } else {
                                    Image(systemName: "face.smiling")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: Self.cellSize, height: Self.cellSize)
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
        .frame(width: Self.pickerSize.width, height: Self.pickerSize.height)
        .onAppear {
            store.loadEmojiCatalogIfNeeded()
            searchFocused = true
        }
    }
}
