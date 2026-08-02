import SwiftUI
import ZulipModel

/// Per-conversation draft persistence (survives switching conversations;
/// local-only for now — server draft sync is M4).
@MainActor
final class DraftStore {
    static let shared = DraftStore()
    private var drafts: [SendDestination: String] = [:]

    func draft(for destination: SendDestination) -> String {
        drafts[destination] ?? ""
    }

    func setDraft(_ text: String, for destination: SendDestination) {
        if text.isEmpty {
            drafts.removeValue(forKey: destination)
        } else {
            drafts[destination] = text
        }
    }
}

/// The Messages-style compose bar. Fixed mode composes into a known
/// conversation; channel mode adds a topic field.
struct ComposeBar: View {
    enum Mode {
        case fixed(SendDestination, placeholder: String)
        case channel(streamId: Int)
    }

    let store: PerAccountStore
    let mode: Mode

    @State private var text = ""
    @State private var topicText = ""
    @FocusState private var messageFocused: Bool

    private var destination: SendDestination? {
        switch mode {
        case .fixed(let destination, _):
            return destination
        case .channel(let streamId):
            let topic = topicText.trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else { return nil }
            return .topic(streamId: streamId, topic: topic)
        }
    }

    private var placeholder: String {
        switch mode {
        case .fixed(_, let placeholder):
            return "Message \(placeholder)"
        case .channel:
            return "Message this topic"
        }
    }

    private var canSend: Bool {
        destination != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .channel = mode {
                TextField("Topic", text: $topicText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 260)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 17))
                    .focused($messageFocused)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return; ⌥Return for a new line)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            if case .fixed(let destination, _) = mode {
                text = DraftStore.shared.draft(for: destination)
            }
        }
        .onChange(of: text) {
            if case .fixed(let destination, _) = mode {
                DraftStore.shared.setDraft(text, for: destination)
            }
        }
    }

    private func send() {
        guard canSend, let destination else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.send(content, to: destination)
        text = ""
        DraftStore.shared.setDraft("", for: destination)
    }
}

/// An optimistically-sent message awaiting its echo (or showing its failure).
struct OutboxRow: View {
    let store: PerAccountStore
    let message: OutboxMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(store: store, userId: store.selfUserId, size: 32)
                .padding(.top, 10)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.users[store.selfUserId]?.fullName ?? "You")
                        .font(.callout.weight(.semibold))
                    switch message.state {
                    case .sending:
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Sending…")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Button("Retry") { store.retrySend(message.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                        Button("Discard") { store.discardSend(message.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .padding(.top, 10)
                Text(message.content)
                    .foregroundStyle(message.state == .sending ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
