import Foundation
import Testing
@testable import ZulipContent

/// Timing probe for message-HTML parsing (the per-row cost of first
/// render; cached per message afterwards). Run with
/// `swift test -c release --filter ParseBenchmarks`.
@Suite struct ParseBenchmarks {
    @Test func contentParsing() {
        let html = """
            <p>Hey <span class="user-mention" data-user-id="12">@Somebody</span>, \
            see <a href="https://example.com/doc">the doc</a> and the list:</p>
            <ul><li>first item</li><li>second item with <code>inline code</code></li></ul>
            <div class="codehilite"><pre><span></span><code>let x = compute(y)
            print(x)</code></pre></div>
            <p>Closing paragraph with more text for realism.</p>
            """
        var blocks = 0
        let parseTime = ContinuousClock().measure {
            for _ in 0..<500 {
                blocks += ContentParser.parse(html: html).blocks.count
            }
        }
        let ms = Double(parseTime.components.seconds) * 1000
            + Double(parseTime.components.attoseconds) / 1e15
        print(String(format: "[bench] parse 500 rich messages: %.1f ms", ms))
        #expect(blocks > 0)
    }
}
