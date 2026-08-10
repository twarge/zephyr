import SwiftUI
import ZulipModel

/// The full-page Outbox: messages that haven't reached the server yet.
/// Queued entries resend on their own when the network returns; failed
/// ones offer a manual retry. Selecting a row opens its conversation
/// (where the pending message also renders in the transcript).
struct OutboxView: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    var body: some View {
        Group {
            if store.outbox.isEmpty {
                ContentUnavailableView(
                    "Outbox Empty", systemImage: "tray.and.arrow.up",
                    description: Text(
                        "Messages that can't reach the server wait here and send automatically when the connection returns."))
            } else {
                List {
                    ForEach(store.outbox) { entry in
                        row(entry)
                    }
                }
            }
        }
        .serverTitled("Outbox", store: store)
    }

    private func row(_ entry: OutboxMessage) -> some View {
        let key = entry.destination.conversationKey(selfUserId: store.selfUserId)
        return Button {
            selection = .conversation(key)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: stateIcon(entry.state).name)
                    .foregroundStyle(stateIcon(entry.state).color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.displayTitle(in: store))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(entry.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text(stateDescription(entry.state))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if case .failed = entry.state {
                    Button("Retry") {
                        store.retrySend(entry.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Send Now") {
                store.retrySend(entry.id)
            }
            Button("Discard", role: .destructive) {
                store.discardSend(entry.id)
            }
        }
    }

    private func stateIcon(_ state: OutboxMessage.State) -> (name: String, color: Color) {
        switch state {
        case .sending: ("arrow.up.circle", .secondary)
        case .queued: ("clock.arrow.circlepath", .orange)
        case .failed: ("exclamationmark.triangle.fill", .red)
        }
    }

    private func stateDescription(_ state: OutboxMessage.State) -> String {
        switch state {
        case .sending: "Sending…"
        case .queued: "Waiting for the network — sends automatically"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
