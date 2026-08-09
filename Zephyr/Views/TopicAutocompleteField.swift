import SwiftUI
import ZulipAPI
import ZulipModel

/// A topic text field with autocomplete: a floating popover-style card lists
/// the channel's existing topics (recency-ordered, filtered as you type).
/// Arrow keys walk the list, Return/Tab/click accepts, Escape dismisses —
/// and typed text that matches nothing stays valid, so new topics work
/// exactly as before.
struct TopicAutocompleteField: View {
    let store: PerAccountStore
    /// nil until a channel is chosen (the new-conversation sheet).
    let streamId: Int?
    @Binding var topic: String
    var prompt = "Topic"
    /// ComposeBar's capsule look; sheets use .roundedBorder.
    var plainStyle = false
    /// In-layout card above the field (the compose bar grows upward — an
    /// overlay floated over neighboring rows) vs. an overlay dropping
    /// below the field (sheets, where growth would jump the layout).
    var dropUp = false
    /// Cap on visible suggestions — sheets with limited room in the card's
    /// direction pass fewer so their bounds never clip it.
    var maxSuggestions = 8
    /// Return with no selection, and every accept, land here (e.g. focus
    /// the message field).
    var onCommit: (() -> Void)?

    @State private var topics: [ChannelTopic]?
    @State private var loadedStreamId: Int?
    @State private var selection = -1
    @State private var dismissed = false
    /// Distinguishes an accept (which must keep the card closed) from
    /// typing in the topic binding's onChange.
    @State private var accepting = false
    @State private var cardHeight: CGFloat = 0
    @FocusState private var focused: Bool

    /// No selection is the default so Return keeps a freshly typed new
    /// topic instead of grabbing the first match.
    private var suggestions: [String] {
        guard focused, !dismissed, let topics else { return [] }
        let typed = topic.trimmingCharacters(in: .whitespaces)
        let names = topics.map(\.name).filter { !$0.isEmpty }
        let matches = typed.isEmpty
            ? names
            : names.filter { $0.localizedCaseInsensitiveContains(typed) }
        // A single exact match is just the committed value echoed back.
        if matches.count == 1,
           matches[0].caseInsensitiveCompare(typed) == .orderedSame {
            return []
        }
        return Array(matches.prefix(maxSuggestions))
    }

    var body: some View {
        Group {
            if dropUp {
                // Floating popover-style card above the field: measured
                // height, so it never pushes layout or covers the field.
                // (A real NSPopover would steal keyboard focus.)
                styledField
                    .overlay(alignment: .topLeading) {
                        if !suggestions.isEmpty {
                            card
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.size.height
                                } action: { height in
                                    cardHeight = height
                                }
                                .offset(y: -(cardHeight + 6))
                                .opacity(cardHeight > 0 ? 1 : 0)
                        }
                    }
            } else {
                styledField
                    .overlay(alignment: .bottomLeading) {
                        if !suggestions.isEmpty {
                            card
                                .alignmentGuide(.bottom) { d in d[.top] - 6 }
                        }
                    }
            }
        }
            .onChange(of: topic) {
                if accepting {
                    accepting = false
                } else {
                    selection = -1
                    dismissed = false
                }
            }
            .onChange(of: focused) {
                if focused { loadIfNeeded() }
            }
            .onChange(of: streamId) {
                topics = nil
                loadedStreamId = nil
                if focused { loadIfNeeded() }
            }
    }

    @ViewBuilder
    private var styledField: some View {
        if plainStyle {
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 17))
        } else {
            field
                .textFieldStyle(.roundedBorder)
        }
    }

    private var field: some View {
        TextField(prompt, text: $topic)
            .focused($focused)
            .autocorrectionDisabled()
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.tab) {
                guard suggestions.indices.contains(selection) else { return .ignored }
                accept(suggestions[selection])
                return .handled
            }
            .onKeyPress(.return) {
                if suggestions.indices.contains(selection) {
                    accept(suggestions[selection])
                    return .handled
                }
                guard let onCommit else { return .ignored }
                dismissed = true
                onCommit()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !suggestions.isEmpty else { return .ignored }
                dismissed = true
                selection = -1
                return .handled
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                Button {
                    accept(name)
                } label: {
                    HStack(spacing: 5) {
                        if TopicName.isResolved(name) {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(TopicName.displayName(name))
                            .lineLimit(1)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        index == selection
                            ? AnyShapeStyle(.tint.opacity(0.2))
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 2)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let list = suggestions
        guard !list.isEmpty else { return .ignored }
        if selection < 0 {
            selection = delta > 0 ? 0 : list.count - 1
        } else {
            selection = (selection + delta + list.count) % list.count
        }
        return .handled
    }

    private func accept(_ name: String) {
        accepting = true
        topic = name
        selection = -1
        dismissed = true
        onCommit?()
    }

    private func loadIfNeeded() {
        guard let streamId, loadedStreamId != streamId else { return }
        loadedStreamId = streamId
        let connection = store.connection
        Task {
            let fetched = (try? await connection.getTopics(streamId: streamId)) ?? []
            guard loadedStreamId == streamId else { return }
            topics = fetched
        }
    }
}
