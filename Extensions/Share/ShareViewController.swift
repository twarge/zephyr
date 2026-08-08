import SwiftUI
import UniformTypeIdentifiers

// The share extension is deliberately thin: it never talks to Zulip. It
// copies the shared attachments into the App Group inbox, shows a brief
// confirmation, and completes; the app offers the destination picker on
// its next activation and sends through its normal upload pipeline.

#if os(macOS)
import AppKit

final class ShareViewController: NSViewController {
    override func loadView() {
        let host = NSHostingView(rootView: ShareConfirmation())
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 130)
        view = host
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ShareIngest.run(context: extensionContext) { [weak self] in
            // Best effort: bring the app up so the picker appears now.
            if let url = URL(string: "zephyr://share") {
                self?.extensionContext?.open(url)
            }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
#else
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareConfirmation())
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        ShareIngest.run(context: extensionContext) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
#endif

private struct ShareConfirmation: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Adding to Zephyr…")
                .font(.callout.weight(.medium))
            Text("Pick the conversation in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 240)
    }
}

/// Thread-safe accumulator for the provider callbacks (they arrive on
/// arbitrary queues).
private final class ShareCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var textParts: [String] = []

    func add(text: String) {
        lock.lock()
        textParts.append(text)
        lock.unlock()
    }

    func copyFile(from url: URL, into directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        var destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "\(UUID().uuidString.prefix(6))-\(url.lastPathComponent)")
        }
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    var joinedText: String? {
        lock.lock()
        defer { lock.unlock() }
        return textParts.isEmpty ? nil : textParts.joined(separator: "\n")
    }
}

enum ShareIngest {
    static func run(context: NSExtensionContext?, completion: @escaping @Sendable () -> Void) {
        guard let directory = ShareInbox.beginItem() else {
            completion()
            return
        }
        let collector = ShareCollector()
        let group = DispatchGroup()
        let providers = (context?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    if let string = string as? String {
                        collector.add(text: string)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    if let url = url as? NSURL, let absolute = url.absoluteString {
                        collector.add(text: absolute)
                    }
                    group.leave()
                }
            } else {
                // Anything file-like: the file representation, copied in
                // before the callback's temporary URL expires.
                let typeId = provider.registeredTypeIdentifiers.first
                    ?? UTType.data.identifier
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                    if let url {
                        collector.copyFile(from: url, into: directory)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            ShareInbox.finishItem(directory, text: collector.joinedText)
            completion()
        }
    }
}
