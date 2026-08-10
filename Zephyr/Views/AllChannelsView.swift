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

    private func matching(_ channels: [ZulipStream]) -> [ZulipStream] {
        let trimmed = search.filterText.trimmingCharacters(in: .whitespaces)
        return channels
            .filter {
                trimmed.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.description.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filtered: [ZulipStream] {
        matching((channels ?? []).filter { $0.isArchived != true })
    }

    private var archivedFiltered: [ZulipStream] {
        matching((channels ?? []).filter { $0.isArchived == true })
    }

    private func refresh() async {
        do {
            channels = try await store.connection.getAllStreams(includeArchived: true)
        } catch {
            if channels == nil {
                errorText = error.localizedDescription
            }
        }
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
                    if !archivedFiltered.isEmpty {
                        Section("Archived") {
                            ForEach(archivedFiltered) { channel in
                                ArchivedChannelRow(store: store, channel: channel) {
                                    Task { await refresh() }
                                }
                            }
                        }
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
        .serverTitled("All Channels", store: store)
        .task { await refresh() }
    }
}

/// Channel subscriber management: who's in, add someone, remove someone.
/// Permissions are server-enforced; refusals surface inline.
struct ManageSubscribersSheet: View {
    let store: PerAccountStore
    let streamId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var subscriberIds: Set<Int>?
    @State private var query = ""
    @State private var errorText: String?

    private var channelName: String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "?"
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Non-subscribers matching the query (add candidates).
    private var addCandidates: [User] {
        guard let subscriberIds, !trimmedQuery.isEmpty else { return [] }
        return Array(
            store.users.values
                .filter {
                    $0.isActive != false && !subscriberIds.contains($0.userId)
                        && $0.fullName.localizedCaseInsensitiveContains(trimmedQuery)
                }
                .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
                .prefix(6))
    }

    /// Subscribers (query-filtered), casefold-sorted — big channels have
    /// thousands, so no ICU collation here.
    private var subscribers: [User] {
        guard let subscriberIds else { return [] }
        return subscriberIds
            .compactMap { store.users[$0] }
            .filter {
                trimmedQuery.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(trimmedQuery)
            }
            .map { (user: $0, key: $0.fullName.lowercased()) }
            .sorted { $0.key < $1.key }
            .map(\.user)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("#\(channelName) subscribers", systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            TextField("Find or add a person…", text: $query)
                .textFieldStyle(.roundedBorder)
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if subscriberIds == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !addCandidates.isEmpty {
                        Section("Add") {
                            ForEach(addCandidates, id: \.userId) { user in
                                row(user, subscribed: false)
                            }
                        }
                    }
                    Section("Subscribed (\(subscriberIds?.count ?? 0))") {
                        ForEach(subscribers, id: \.userId) { user in
                            row(user, subscribed: true)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 360, height: 440)
        .task {
            do {
                subscriberIds = Set(try await store.fetchSubscribers(streamId: streamId))
            } catch {
                errorText = (error as? ApiError)?.message ?? error.localizedDescription
            }
        }
    }

    private func row(_ user: User, subscribed: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(store: store, userId: user.userId, size: 22)
            Text(user.userId == store.selfUserId ? "\(user.fullName) (you)" : user.fullName)
                .lineLimit(1)
            Spacer()
            if subscribed {
                Button("Remove") { remove(user) }
                    .controlSize(.small)
            } else {
                Button("Add") { add(user) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 1)
    }

    private func add(_ user: User) {
        errorText = nil
        Task {
            do {
                try await store.addSubscriber(userId: user.userId, toChannel: streamId)
                subscriberIds?.insert(user.userId)
                query = ""
            } catch {
                errorText = (error as? ApiError)?.message ?? error.localizedDescription
            }
        }
    }

    private func remove(_ user: User) {
        errorText = nil
        Task {
            do {
                try await store.removeSubscriber(userId: user.userId, fromChannel: streamId)
                subscriberIds?.remove(user.userId)
            } catch {
                errorText = (error as? ApiError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// An archived channel: dimmed, with restore (admin-gated server-side;
/// refusals show inline).
private struct ArchivedChannelRow: View {
    let store: PerAccountStore
    let channel: ZulipStream
    var onUnarchived: () -> Void

    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if !channel.description.isEmpty {
                    Text(channel.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Unarchive") {
                unarchive()
            }
            .controlSize(.small)
            .disabled(working)
        }
        .padding(.vertical, 3)
    }

    private func unarchive() {
        working = true
        errorText = nil
        Task {
            do {
                try await store.unarchiveChannel(channel.streamId)
                onUnarchived()
            } catch {
                errorText = (error as? ApiError)?.message ?? error.localizedDescription
                working = false
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
