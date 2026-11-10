import SwiftUI
import UniformTypeIdentifiers

// The share extension is deliberately thin: it never talks to Zulip. It
// copies the shared attachments into the App Group inbox, shows a brief
// confirmation, and completes; the app offers the destination picker on
// its next activation and sends through its normal upload pipeline.

#if os(macOS)
import AppKit

final class ShareViewController: NSViewController {
    private let state = ShareState()

    override func loadView() {
        let host = NSHostingView(rootView: ShareConfirmation(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 130)
        view = host
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        state.onDone = { [weak self] added in
            // Best effort: bring the app up so the picker appears now.
            if added, let url = URL(string: "zephyr://share") {
                _ = await self?.extensionContext?.open(url)
            }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        ShareIngest.run(context: extensionContext) { [state] outcome in
            // extensionContext is main-actor-isolated; the ingest callback
            // isn't.
            Task { @MainActor in state.finish(outcome) }
        }
    }
}
#else
import UIKit

final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareConfirmation(state: state))
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        state.onDone = { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        ShareIngest.run(context: extensionContext) { [state] outcome in
            Task { @MainActor in state.finish(outcome) }
        }
    }
}
#endif

/// What the ingest managed: whether anything reached the inbox, and the
/// names of attachments that couldn't be read or copied.
struct ShareOutcome: Sendable {
    var added: Bool
    var failures: [String]
}

@MainActor
@Observable
final class ShareState {
    private(set) var outcome: ShareOutcome?
    var onDone: (@MainActor (_ added: Bool) async -> Void)?

    /// A clean share dismisses itself; one with failures stays up until
    /// the user has seen what was dropped.
    func finish(_ outcome: ShareOutcome) {
        self.outcome = outcome
        if outcome.failures.isEmpty {
            done()
        }
    }

    func done() {
        let added = outcome?.added ?? false
        Task { await onDone?(added) }
    }
}

private struct ShareConfirmation: View {
    let state: ShareState

    var body: some View {
        VStack(spacing: 8) {
            if let outcome = state.outcome, !outcome.failures.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(outcome.added
                     ? "Some items couldn't be added"
                     : "Couldn't add to Zephyr")
                    .font(.callout.weight(.medium))
                Text(outcome.failures.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                if outcome.added {
                    Text("The rest will be waiting in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Done") { state.done() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            } else {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Adding to Zephyr…")
                    .font(.callout.weight(.medium))
                Text("Pick the conversation in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    private var fileCount = 0
    private var failureNames: [String] = []

    func add(text: String) {
        lock.withLock { textParts.append(text) }
    }

    func fail(_ name: String) {
        lock.withLock { failureNames.append(name) }
    }

    /// Copies (or, for a package/folder, zips) `url` into the item
    /// directory under `name`. Must run inside the provider callback,
    /// before its temporary URL is deleted.
    func copyFile(from url: URL, named name: String, into directory: URL) {
        var name = name
        var coordinatorError: NSError?
        var copyError: Error?
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let copy = { (from: URL) in
            self.lock.lock()
            defer { self.lock.unlock() }
            var destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(name)")
            }
            do {
                try FileManager.default.copyItem(at: from, to: destination)
                self.fileCount += 1
            } catch {
                copyError = error
            }
        }
        if isDirectory {
            // Bundles (.rtfd, .pages, Live Photo) and folders can't be
            // uploaded as-is; the coordinator's upload form is a zip.
            name += ".zip"
            NSFileCoordinator().coordinate(
                readingItemAt: url, options: .forUploading, error: &coordinatorError
            ) { zipped in
                copy(zipped)
            }
        } else {
            copy(url)
        }
        if coordinatorError != nil || copyError != nil {
            fail(name)
        }
    }

    var outcome: (text: String?, hasFiles: Bool, failures: [String]) {
        lock.withLock {
            (textParts.isEmpty ? nil : textParts.joined(separator: "\n"),
             fileCount > 0, failureNames)
        }
    }
}

enum ShareIngest {
    static func run(
        context: NSExtensionContext?, completion: @escaping @Sendable (ShareOutcome) -> Void
    ) {
        guard let directory = ShareInbox.beginItem() else {
            completion(ShareOutcome(added: false, failures: ["Zephyr's shared storage isn't available"]))
            return
        }
        let collector = ShareCollector()
        let group = DispatchGroup()
        let providers = (context?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        for (index, provider) in providers.enumerated() {
            let label = provider.suggestedName ?? "Item \(index + 1)"
            let fileType = fileType(for: provider)
            // File-backed means the sender handed us a document: a file
            // URL, or a named item with a data representation. Checked
            // before plain text, since .txt/.log/source files conform to
            // it and would otherwise be pasted instead of attached.
            let isFileBacked = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || (provider.suggestedName != nil && fileType != nil)

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    if let url = url as? NSURL, let absolute = url.absoluteString {
                        collector.add(text: absolute)
                    } else {
                        collector.fail(label)
                    }
                    group.leave()
                }
            } else if isFileBacked || !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let fileType {
                    let suggested = provider.suggestedName
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: fileType.identifier) { url, _ in
                        if let url {
                            collector.copyFile(
                                from: url, named: fileName(suggested, url: url, type: fileType),
                                into: directory)
                        } else {
                            collector.fail(label)
                        }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    // Only a file URL on offer (e.g. a Finder folder).
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        if let url = fileURL(from: item) {
                            let scoped = url.startAccessingSecurityScopedResource()
                            collector.copyFile(from: url, named: url.lastPathComponent, into: directory)
                            if scoped { url.stopAccessingSecurityScopedResource() }
                        } else {
                            collector.fail(label)
                        }
                        group.leave()
                    }
                } else {
                    collector.fail(label)
                }
            } else {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    if let string = string as? String {
                        collector.add(text: string)
                    } else {
                        collector.fail(label)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let (text, hasFiles, failures) = collector.outcome
            guard hasFiles || text != nil else {
                // Nothing usable: don't leave an empty item for the app.
                try? FileManager.default.removeItem(at: directory)
                completion(ShareOutcome(
                    added: false, failures: failures.isEmpty ? ["Nothing to share"] : failures))
                return
            }
            guard ShareInbox.finishItem(directory, text: text) else {
                try? FileManager.default.removeItem(at: directory)
                completion(ShareOutcome(added: false, failures: ["Couldn't save the share"]))
                return
            }
            ShareInbox.postChanged()
            completion(ShareOutcome(added: true, failures: failures))
        }
    }

    /// The representation to copy: the first registered concrete data type
    /// (registration order is the sender's preference), skipping URL types
    /// and packages — a Live Photo's bundle or an .rtfd usually also offers
    /// a flat type (JPEG/HEIC, RTF). A package is used, zipped, only when
    /// nothing flat is on offer.
    private static func fileType(for provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .filter { !$0.conforms(to: .url) }
        let isPackage = { (type: UTType) in
            type.conforms(to: .package) || type.conforms(to: .directory)
        }
        return types.first { $0.conforms(to: .data) && !isPackage($0) }
            ?? types.first(where: isPackage)
    }

    /// The sender's name when it gave one (with the type's extension if
    /// missing), else the temporary file's own name.
    private static func fileName(_ suggested: String?, url: URL, type: UTType) -> String {
        guard let suggested, !suggested.isEmpty else {
            return url.lastPathComponent
        }
        let hasExtension = !(suggested as NSString).pathExtension.isEmpty
        if hasExtension { return suggested }
        let ext = type.preferredFilenameExtension ?? url.pathExtension
        return ext.isEmpty ? suggested : "\(suggested).\(ext)"
    }

    /// loadItem's file-URL payload arrives as a URL or its data form.
    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}
