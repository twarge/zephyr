import SwiftUI
import ZulipModel

/// Placeholder shell; the Messages-style window (unified sidebar + transcript)
/// lands in M1.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Zulip for macOS")
                .font(.title2.weight(.semibold))
            Text("M0 foundations in place — the UI lands in M1.")
                .foregroundStyle(.secondary)
            Text("Supports Zulip Server \(ServerCompat.minVersionLabel)+ (feature level \(ServerCompat.minFeatureLevel)+)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
