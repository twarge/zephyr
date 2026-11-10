#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import TipKit
import ZulipAPI
import ZulipContent
import ZulipModel

/// Dims explicitly colored sidebar decorations when the window is
/// inactive, matching the system's automatic Label-icon behavior (which
/// covers only system-styled icons).
struct DimsWhenWindowInactive: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .grayscale(appearsActive ? 0 : 1)
            .opacity(appearsActive ? 1 : 0.55)
    }
}

/// A sidebar icon in an explicit color, dimmed for an inactive window —
/// what the channel rows' colored # already did. Left to the list (an
/// unstyled Label icon, or a semantic style like .secondary), the sidebar
/// tints icons itself, but redraws them through each change in the
/// window's state: every window that opened (or closed) showed its rows
/// icon-less for a few frames, twice over, while the channel #s held. A
/// concrete color draws in the same pass as the row's text. White on a
/// prominent (accent-filled) selection, as the list's own tint would be.
struct SidebarIconStyle: ViewModifier {
    var color: Color = .accentColor
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content
            .foregroundStyle(prominence == .increased ? .white : color)
            .dimsWhenWindowInactive()
    }
}

extension View {
    func dimsWhenWindowInactive() -> some View {
        modifier(DimsWhenWindowInactive())
    }

    func sidebarIcon(_ color: Color = .accentColor) -> some View {
        modifier(SidebarIconStyle(color: color))
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        // Native sidebar counts (Mail's on both platforms): plain
        // secondary numbers, no capsule.
        Text("\(count)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// Channel-colored `#` (or lock) badge, used by feed/topic-list contexts.
struct ChannelBadge: View {
    let store: PerAccountStore
    let streamId: Int
    var size: CGFloat = 34

    var body: some View {
        let color = store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
        Image(systemName: store.channels[streamId]?.inviteOnly == true ? "lock.fill" : "number")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
    }
}

extension Color {
    /// Parses Zulip's subscription color strings ("#e79ab5").
    init?(zulipHex: String) {
        var hex = zulipHex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }

    /// A stable per-id hue for avatars/badges without server colors.
    static func stableColor(for id: Int) -> Color {
        Color(hue: Double((id &* 2654435761) % 360) / 360, saturation: 0.55, brightness: 0.75)
    }

    /// The inverse of `init(zulipHex:)`, for writing colors back.
    var zulipHexString: String {
        #if os(macOS)
        let platform = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let red = platform.redComponent
        let green = platform.greenComponent
        let blue = platform.blueComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
    }
}
