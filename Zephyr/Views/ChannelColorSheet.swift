#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import TipKit
import ZulipAPI
import ZulipContent
import ZulipModel

/// "Change Color…": Zulip web's default stream palette plus a custom
/// picker. Picking a swatch applies immediately.
struct ChannelColorSheet: View {
    let store: PerAccountStore
    let streamId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .accentColor

    private static let palette = [
        "#76ce90", "#fae589", "#a6c7e5", "#e79ab5", "#bfd56f", "#f4ae55",
        "#b0a5fd", "#addfe5", "#f5ce6e", "#c2726a", "#94c849", "#bd86e5",
        "#ee7e4a", "#a6dcbf", "#95a5fd", "#53a063", "#9987e1", "#e4523d",
        "#c2c2c2", "#4f8de4", "#c6a8ad", "#e7cc4d", "#c8bebf", "#a47462",
    ]

    // Touch-sized swatches on iOS; compact pointer-sized wells on macOS.
    #if os(macOS)
    private nonisolated static let swatchSize: CGFloat = 24
    private nonisolated static let gridSpacing: CGFloat = 8
    #else
    private nonisolated static let swatchSize: CGFloat = 40
    private nonisolated static let gridSpacing: CGFloat = 10
    #endif

    private var title: String {
        guard let name = store.subscriptions[streamId]?.name else {
            return "Channel Color"
        }
        return "Channel Color: \(name)"
    }

    var body: some View {
        #if os(macOS)
        sheetContent
            .padding(16)
            .frame(width: 244)
            .onAppear(perform: seedCustomColor)
        #else
        // Half-height sheet: the content is compact, so the sheet
        // shouldn't climb to full screen (scrolls only if it must).
        ScrollView {
            sheetContent
                .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear(perform: seedCustomColor)
        #endif
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: Self.swatchSize)),
                    count: 6),
                spacing: Self.gridSpacing
            ) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        store.setChannelColor(streamId, hex: hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(zulipHex: hex) ?? .gray)
                            .frame(width: Self.swatchSize, height: Self.swatchSize)
                            .overlay {
                                if store.subscriptions[streamId]?.color?.lowercased() == hex {
                                    Image(systemName: "checkmark")
                                        .font(checkmarkFont)
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $custom, supportsOpacity: false)
            #if os(macOS)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { applyCustomColor() }
                    .keyboardShortcut(.defaultAction)
            }
            #else
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button {
                    applyCustomColor()
                } label: {
                    Text("Set")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            #endif
        }
    }

    private var checkmarkFont: Font {
        #if os(macOS)
        .caption.bold()
        #else
        .body.bold()
        #endif
    }

    private func applyCustomColor() {
        store.setChannelColor(streamId, hex: custom.zulipHexString)
        dismiss()
    }

    private func seedCustomColor() {
        if let hex = store.subscriptions[streamId]?.color,
           let color = Color(zulipHex: hex) {
            custom = color
        }
    }
}
