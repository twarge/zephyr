import SwiftUI
import ZulipModel

@main
struct ZulipApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(minWidth: 400, minHeight: 300)
            case .needsAccount:
                LoginView()
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Couldn't connect")
                        .font(.headline)
                    ScrollView {
                        Text(message)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 520, maxHeight: 180)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Retry") {
                            Task { await model.retry() }
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Sign Out") {
                            Task { await model.signOut() }
                        }
                    }
                }
                .padding(40)
                .frame(minWidth: 480, minHeight: 340)
            case .ready(let accountId):
                if let store = model.global.stores[accountId] {
                    MainSplitView(store: store)
                } else {
                    ProgressView()
                        .frame(minWidth: 400, minHeight: 300)
                }
            }
        }
        .task { await model.start() }
    }
}
