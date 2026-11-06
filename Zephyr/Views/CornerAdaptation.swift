import SwiftUI

/// The axis a view anchored in a container's corner moves along to clear it.
enum CornerAdaptationAxis: Sendable {
    case horizontal
    case vertical
}

extension View {
    /// Overlays `content` at `alignment`, inset by `padding` and, on iOS 26
    /// and macOS 26 and later, moved along `axis` far enough to clear the
    /// container's rounded corner there — the display's corner on iPhone,
    /// the window's on Mac and iPad — and system UI in that corner, such as
    /// window controls. Before those releases it is inset by `padding` only.
    func cornerAdaptiveOverlay<Content: View>(
        alignment: Alignment,
        padding: CGFloat = 16,
        axis: CornerAdaptationAxis = .horizontal,
        @ViewBuilder content: () -> Content
    ) -> some View {
        overlay {
            CornerAdaptiveAnchor(alignment: alignment, padding: padding, axis: axis, content: content())
        }
    }

    /// Fills behind the view with `style` in a rectangle whose corners are
    /// concentric with the container's on iOS 26 and macOS 26 and later,
    /// never tighter than `minimumRadius`; before those releases, a rounded
    /// rectangle of `minimumRadius`.
    @ViewBuilder
    func concentricBackground<S: ShapeStyle>(_ style: S, minimumRadius: CGFloat) -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            background(style, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(minimumRadius))))
        } else {
            background(style, in: RoundedRectangle(cornerRadius: minimumRadius, style: .continuous))
        }
    }
}

private struct CornerAdaptiveAnchor<Content: View>: View {
    let alignment: Alignment
    let padding: CGFloat
    let axis: CornerAdaptationAxis
    let content: Content

    var body: some View {
        GeometryReader { proxy in
            content
                .padding(insets(in: proxy))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    private func insets(in proxy: GeometryProxy) -> EdgeInsets {
        var insets = EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
        guard #available(iOS 26, macOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return insets }
        let corners = proxy.containerCornerInsets
        let safe = proxy.safeAreaInsets
        let top = alignment.vertical == .top
        let bottom = alignment.vertical == .bottom
        guard top || bottom else { return insets }
        let leading = alignment.horizontal != .trailing
        let trailing = alignment.horizontal != .leading

        func adapt(_ region: CGSize, vertical: CGFloat, horizontal: CGFloat, _ edge: Edge) {
            var region = region
            #if os(macOS)
            // AppKit measures the window controls from the window's edge even
            // where the toolbar's safe area already holds them, so take off
            // what the safe area covers; elsewhere the size is measured from
            // the safe area already.
            region.width -= horizontal
            region.height -= vertical
            #endif
            // Placed `padding` in from the safe area, the content's corner
            // clears the region unless it falls inside it on both axes.
            guard region.width > padding, region.height > padding else { return }
            switch edge {
            case .leading: insets.leading = max(insets.leading, region.width)
            case .trailing: insets.trailing = max(insets.trailing, region.width)
            case .top: insets.top = max(insets.top, region.height)
            case .bottom: insets.bottom = max(insets.bottom, region.height)
            }
        }

        let verticalEdge: Edge = top ? .top : .bottom
        let verticalSafe = top ? safe.top : safe.bottom
        if leading {
            adapt(top ? corners.topLeading : corners.bottomLeading, vertical: verticalSafe, horizontal: safe.leading,
                  axis == .horizontal ? .leading : verticalEdge)
        }
        if trailing {
            adapt(top ? corners.topTrailing : corners.bottomTrailing, vertical: verticalSafe, horizontal: safe.trailing,
                  axis == .horizontal ? .trailing : verticalEdge)
        }
        // Centred content stays centred: what one side needs, both get.
        if alignment.horizontal == .center {
            insets.leading = max(insets.leading, insets.trailing)
            insets.trailing = insets.leading
        }
        return insets
    }
}
