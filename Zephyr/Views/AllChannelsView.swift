import SwiftUI
import ZulipAPI
import ZulipModel

/// The channel browser: every channel you can see, with subscribe /
/// unsubscribe. Clicking a name opens its feed (public channel history is
/// readable without subscribing).
struct AllChannelsView: View {
    let store: PerAccountStore
    let search: SidebarSearchModel
    @Binding var selection: Destination?

    @State private var channels: [ZulipStream]?
    @State private var errorText: String?
    @State private var showNewChannel = false

    private var filtered: [ZulipStream] {
        guard let channels else { return [] }
        let trimmed = search.filterText.trimmingCharacters(in: .whitespaces)
        return channels
            .filter {
                trimmed.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.description.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if channels != nil {
                // Filtered by the shared toolbar search field, NOT its own
                // .searchable: a second toolbar search item crashes
                // NSToolbar (duplicate com.apple.SwiftUI.search identifier).
                List {
                    Button {
                        showNewChannel = true
                    } label: {
                        Label("New Channel…", systemImage: "plus.circle")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    ForEach(filtered) { channel in
                        ChannelBrowserRow(store: store, channel: channel, selection: $selection)
                    }
                }
                .sheet(isPresented: $showNewChannel) {
                    NewChannelSheet(store: store, selection: $selection)
                }
            } else if let errorText {
                ContentUnavailableView(
                    "Couldn't Load Channels", systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("All Channels")
        .task {
            do {
                channels = try await store.connection.getAllStreams()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Creates a channel (server-side permission applies) and opens it.
private struct NewChannelSheet: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var isPrivate = false
    @State private var announce = true
    @State private var creating = false
    @State private var errorText: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Channel")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $descriptionText)
                .textFieldStyle(.roundedBorder)
            Toggle("Private channel (invite only)", isOn: $isPrivate)
            Toggle("Announce the new channel", isOn: $announce)
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || creating)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func create() {
        creating = true
        errorText = nil
        let channelName = trimmedName
        Task {
            do {
                try await store.createChannel(
                    name: channelName,
                    description: descriptionText.trimmingCharacters(in: .whitespaces),
                    inviteOnly: isPrivate, announce: announce)
                // The subscription event delivers the new channel; open it
                // once its id lands.
                for _ in 0..<20 {
                    if let created = store.subscriptions.values.first(
                        where: { $0.name == channelName }) {
                        selection = .channel(streamId: created.streamId)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                dismiss()
            } catch {
                errorText = (error as? ApiError)?.message ?? error.localizedDescription
                creating = false
            }
        }
    }
}

private struct ChannelBrowserRow: View {
    let store: PerAccountStore
    let channel: ZulipStream
    @Binding var selection: Destination?

    private var isSubscribed: Bool {
        store.subscriptions[channel.streamId] != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: channel.inviteOnly
                ? "lock.fill" : (channel.isWebPublic == true ? "globe" : "number"))
                .font(.callout.weight(.medium))
                .foregroundStyle(
                    store.subscriptions[channel.streamId]?.color
                        .flatMap(Color.init(zulipHex:)) ?? .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    selection = .channel(streamId: channel.streamId)
                } label: {
                    Text(channel.name)
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                if !channel.description.isEmpty {
                    Text(channel.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isSubscribed {
                Button("Unsubscribe") {
                    store.unsubscribe(fromChannel: channel.name)
                }
                .controlSize(.small)
            } else {
                Button("Subscribe") {
                    store.subscribe(toChannel: channel.name)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 3)
    }
}
