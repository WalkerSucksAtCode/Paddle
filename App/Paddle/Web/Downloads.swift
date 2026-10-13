import AppKit
import Foundation
import os
import WebKit

/// One download, shown in the toolbar's downloads popover.
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    var filename: String
    var destination: URL?
    var fraction: Double = 0
    var receivedBytes: Int64 = 0
    /// Total size, or nil when the server didn't say (no Content-Length).
    var expectedBytes: Int64?
    var state: State = .running
    /// Started in a private window: dropped from the list when the last private window closes.
    let isPrivate: Bool
    /// A private download still running when the last private window closed: it leaves the list when it ends.
    @ObservationIgnored var outlivedPrivateWindows = false

    @ObservationIgnored let download: WKDownload
    @ObservationIgnored var progressObservation: NSKeyValueObservation?

    init(download: WKDownload, isPrivate: Bool) {
        self.download = download
        self.isPrivate = isPrivate
        self.filename = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }
}

/// Saves downloads to ~/Downloads. Files get the quarantine flag (LSFileQuarantineEnabled in Info.plist),
/// so Gatekeeper checks anything you open from them, as it does for Safari downloads.
@Observable
final class DownloadStore {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private lazy var delegate = DownloadDelegate(store: self)

    var activeCount: Int { items.filter { $0.state == .running }.count }

    /// The list lives in memory only; Paddle keeps no download history on disk, private or not.
    func track(_ download: WKDownload, isPrivate: Bool) {
        let item = DownloadItem(download: download, isPrivate: isPrivate)
        download.delegate = delegate
        // Progress KVO can fire on any thread, so this closure is explicitly non-isolated and hops to main. It fires
        // for every chunk received; the coalescer turns that into at most four updates a second, each reading the
        // latest counts.
        let coalescer = ProgressCoalescer()
        item.progressObservation = download.progress.observe(\.completedUnitCount) { @Sendable [weak item] progress, _ in
            coalescer.schedule {
                let received = progress.completedUnitCount
                let total = progress.totalUnitCount
                guard let item, received >= item.receivedBytes else { return }
                item.receivedBytes = received
                item.expectedBytes = total > 0 ? total : nil
                // An update landing after the finish leaves its fraction of 1.
                if item.state == .running { item.fraction = total > 0 ? Double(received) / Double(total) : 0 }
            }
        }
        items.insert(item, at: 0)
    }

    func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func cancel(_ item: DownloadItem) {
        item.state = .cancelled
        item.download.cancel { _ in
            Task { @MainActor in Self.removePartialFile(of: item) }
        }
        ended(item)
    }

    /// A download finished, failed or was cancelled. One that outlived the private windows it came from goes.
    func ended(_ item: DownloadItem) {
        guard item.outlivedPrivateWindows else { return }
        items.removeAll { $0 === item }
    }

    /// Quitting stops running downloads; their partial files go with them.
    func discardRunning() {
        for item in items where item.state == .running {
            item.state = .cancelled
            Self.removePartialFile(of: item)
        }
    }

    /// Paddle doesn't resume downloads, so a cancelled or failed one leaves no truncated file under the real name.
    static func removePartialFile(of item: DownloadItem) {
        guard item.state != .finished, let destination = item.destination,
              FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    /// The last private window closed: its finished, failed and cancelled downloads leave the list (the files
    /// stay). Running ones stay, so they can still be watched or cancelled, and leave on their own when they end.
    func forgetPrivate() {
        for item in items where item.isPrivate && item.state == .running { item.outlivedPrivateWindows = true }
        items.removeAll { $0.isPrivate && $0.state != .running }
    }

    /// A free name in ~/Downloads: "name (1).ext" when "name.ext" exists on disk or belongs to a running download.
    func uniqueDestination(for filename: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        // Lowercased: the Downloads volume is normally case-insensitive.
        let reserved = Set(items.filter { $0.state == .running }.compactMap { $0.destination?.path.lowercased() })
        var candidate = folder.appending(path: safe)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path.lowercased()) {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appending(path: name)
            n += 1
        }
        return candidate
    }
}

/// Runs a main-thread update at most once per `interval`, however often `schedule` is called from any thread: the
/// first call in a quiet period schedules the update, later ones until it runs are dropped (the update reads the
/// latest values when it runs, so nothing is lost but the in-between steps).
nonisolated final class ProgressCoalescer: Sendable {
    private let interval: TimeInterval
    private let pending = OSAllocatedUnfairLock(initialState: false)

    init(interval: TimeInterval = 0.25) {
        self.interval = interval
    }

    func schedule(_ update: @escaping @MainActor @Sendable () -> Void) {
        let first = pending.withLock { pending in
            defer { pending = true }
            return !pending
        }
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [pending] in
            pending.withLock { $0 = false }
            MainActor.assumeIsolated { update() }
        }
    }
}

final class DownloadDelegate: NSObject, WKDownloadDelegate {
    private weak var store: DownloadStore?

    init(store: DownloadStore) {
        self.store = store
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let store else { return nil }
        let destination = store.uniqueDestination(for: suggestedFilename)
        if let item = store.item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
            AccessibilityNotification.Announcement("Downloading \(item.filename)").post()
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = store?.item(for: download) else { return }
        item.state = .finished
        item.fraction = 1
        AccessibilityNotification.Announcement("\(item.filename) downloaded").post()
        if let path = item.destination?.path {
            // Bounces the Downloads stack in the Dock, as Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
        store?.ended(item)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = store?.item(for: download), item.state != .cancelled else { return }
        item.state = .failed(error.localizedDescription)
        AccessibilityNotification.Announcement("\(item.filename) failed to download").post()
        // "File exists" means the file at that path isn't this download's, so leave it alone.
        let nsError = error as NSError
        if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError) {
            DownloadStore.removePartialFile(of: item)
        }
        store?.ended(item)
    }

}
