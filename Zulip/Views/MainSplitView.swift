import SwiftUI
import ZulipModel

/// The Messages-style main window: unified conversation sidebar + transcript.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let store: PerAccountStore
    @State private var selection: ConversationKey?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            if let selection {
                TranscriptView(store: store, conversation: selection)
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar."))
            }
        }
        .navigationTitle(store.realmName ?? "Zulip")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Text(model.global.accounts.first?.email ?? "")
                    Divider()
                    Button("Sign Out…") {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isRecoveringEventStream {
                Label("Connecting…", systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.2), in: .rect)
            }
        }
    }
}
