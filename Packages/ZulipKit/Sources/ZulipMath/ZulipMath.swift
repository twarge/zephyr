#if canImport(AppKit)
import AppKit
public typealias MathImage_Platform = NSImage
public typealias MathColor = NSColor
#else
import UIKit
public typealias MathImage_Platform = UIImage
public typealias MathColor = UIColor
#endif
import SwiftMath

/// Native math rendering from TeX source via SwiftMath (a TeX typesetter with
/// bundled math fonts) — the same architecture zulip-flutter landed on after
/// abandoning KaTeX-HTML/CSS interpretation (zulip-flutter#2323): the server's
/// KaTeX annotation gives us the TeX source; a real typesetter renders it.
/// Anything the typesetter can't parse falls back to showing the source.
public enum ZulipMath {
    /// A typeset expression: a resolution-independent image plus the distance
    /// from the image bottom up to the math baseline (for inline alignment).
    public struct Rendered {
        public let image: MathImage_Platform
        public let descent: CGFloat
    }

    /// Whether SwiftMath can typeset this expression (callers fall back to
    /// showing the TeX source otherwise).
    public static func parses(_ tex: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: tex, error: &error)
        return list != nil && error == nil
    }

    private final class CacheEntry {
        let rendered: Rendered
        init(_ rendered: Rendered) { self.rendered = rendered }
    }

    @MainActor
    private static let cache = NSCache<NSString, CacheEntry>()

    @MainActor
    public static func render(
        tex: String, fontSize: CGFloat, color: MathColor, display: Bool
    ) -> Rendered? {
        let key = "\(fontSize)|\(display)|\(color.description)|\(tex)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.rendered
        }
        var math = MathImage(
            latex: tex, fontSize: fontSize, textColor: color,
            labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, image.size.width > 0 else {
            return nil
        }
        let rendered = Rendered(image: image, descent: layout?.descent ?? 0)
        cache.setObject(CacheEntry(rendered), forKey: key)
        return rendered
    }
}
