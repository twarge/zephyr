import AppKit
import Testing
@testable import ZulipMath

struct ZulipMathTests {
    @Test func parsesCommonExpressions() {
        #expect(ZulipMath.parses("x^2"))
        #expect(ZulipMath.parses(#"\frac{1}{2} + \sqrt{x}"#))
        #expect(ZulipMath.parses(#"\sum_{i=1}^n i = \frac{n(n+1)}{2}"#))
        #expect(ZulipMath.parses(#"e^{i\pi} + 1 = 0"#))
    }

    @Test func rejectsMalformedTex() {
        #expect(!ZulipMath.parses(#"\frac{1}{"#))
        #expect(!ZulipMath.parses(#"x^{2"#))
    }

    @Test @MainActor func rendersWithBaselineInfo() {
        let rendered = ZulipMath.render(
            tex: "e = mc^2", fontSize: 16, color: .black, display: true)
        #expect(rendered != nil)
        #expect((rendered?.image.size.width ?? 0) > 10)
        #expect((rendered?.image.size.height ?? 0) > 5)

        // Descenders (the "y" in a fraction) yield a positive descent.
        let fraction = ZulipMath.render(
            tex: #"\frac{x}{y}"#, fontSize: 16, color: .black, display: false)
        #expect((fraction?.descent ?? 0) > 0)
    }

    @Test @MainActor func unparseableRendersNil() {
        #expect(
            ZulipMath.render(tex: #"\frac{1}{"#, fontSize: 16, color: .black, display: false)
                == nil)
    }
}
