import SwiftUI

/// One in-flight attachment download: the toolbar indicator's data and its
/// cancel handle. `revealed` flips after a beat so the common quick
/// download never flashes the indicator into the toolbar.
@Observable
final class AttachmentDownload: Identifiable {
    let url: URL
    /// The URL's idea of the name — good enough for the tooltip; the
    /// server's Content-Disposition names the saved file.
    let filename: String
    var received: Int64 = 0
    var total: Int64?
    var revealed = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        filename = url.lastPathComponent.removingPercentEncoding
            .flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
    }
}

/// The toolbar's download indicator: a filling ring while every active
/// download declares its size, a plain spinner when one doesn't. Clicking
/// cancels — the ring doubles as the only "stop" affordance, so it carries
/// a stop glyph rather than a downward arrow.
struct DownloadProgressButton: View {
    let downloads: [AttachmentDownload]

    /// Aggregate fraction across simultaneous downloads (Safari-style);
    /// nil — indeterminate — until every server has declared a total.
    private var fraction: Double? {
        let totals = downloads.compactMap(\.total)
        guard totals.count == downloads.count else { return nil }
        let total = totals.reduce(0, +)
        guard total > 0 else { return nil }
        let received = downloads.reduce(Int64(0)) { $0 + $1.received }
        return min(1, Double(received) / Double(total))
    }

    private var helpText: String {
        downloads.count == 1
            ? "Downloading “\(downloads[0].filename)” — click to cancel"
            : "Downloading \(downloads.count) files — click to cancel"
    }

    var body: some View {
        Button {
            for download in downloads {
                download.task?.cancel()
            }
        } label: {
            ZStack {
                if let fraction {
                    Circle()
                        .stroke(.tertiary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.default, value: fraction)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 6))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 16, height: 16)
        }
        .help(helpText)
        .accessibilityLabel("Cancel download")
        .accessibilityValue(
            fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")
    }
}
