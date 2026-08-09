import SwiftUI
import ZulipAPI
import ZulipModel

/// Pending reminders, soonest first: where each will point, when it fires,
/// and a cancel button. Rows open the target message's conversation.
struct RemindersView: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    private var rows: [Reminder] {
        store.reminders.values.sorted {
            $0.scheduledDeliveryTimestamp < $1.scheduledDeliveryTimestamp
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Reminders", systemImage: "clock",
                    description: Text(
                        "Set one from a message's context menu: Remind Me About This."))
            } else {
                List(rows) { reminder in
                    ReminderRow(store: store, reminder: reminder, selection: $selection)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Reminders")
        .task { await store.refreshReminders() }
    }
}

private struct ReminderRow: View {
    let store: PerAccountStore
    let reminder: Reminder
    @Binding var selection: Destination?

    private var message: Message? {
        store.messages[reminder.reminderTargetMessageId]
    }

    private var deliveryText: String {
        Date(timeIntervalSince1970: TimeInterval(reminder.scheduledDeliveryTimestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let message,
                   let key = Unreads.conversationKey(
                       for: message, selfUserId: store.selfUserId) {
                    Button {
                        selection = .conversation(key)
                    } label: {
                        Text(key.displayTitle(in: store))
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    Text(message.senderFullName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // The target message may be outside the cached window.
                    Text("Message #\(reminder.reminderTargetMessageId)")
                        .font(.body.weight(.medium))
                }
                Text(deliveryText)
                    .font(.callout.smallCaps())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                store.cancelReminder(reminder.reminderId)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
