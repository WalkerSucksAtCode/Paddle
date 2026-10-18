import PaddleCore
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
    let startedAt = Date()
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

    /// The window whose tab started it: the save panel is its sheet and its downloads popover opens. Captured at the
    /// start, since a tab opened only for the download closes as soon as the download begins.
    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored weak var window: NSWindow?

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

    /// What one window lists: a normal window never shows private downloads (their names and addresses would leak
    /// out of private browsing); a private window shows everything.
    func items(forPrivateWindow isPrivate: Bool) -> [DownloadItem] {
        isPrivate ? items : items.filter { !$0.isPrivate }
    }

    /// `downloadFolder` from config.json (`~` expanded), or ~/Downloads when it is empty or not an existing folder.
    static var folder: URL { folder(using: AppModel.shared.config) }

    /// `config`'s `downloadFolder`, as `folder` (a window's profile may set its own).
    static func folder(using config: PaddleConfig) -> URL {
        let configured = (config.downloadFolder as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !configured.isEmpty, FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// "Downloads" or a path with `~` for the home folder, for Settings. A folder that no longer exists says so.
    static func folderDisplayName(_ configured: String) -> String {
        let path = (configured as NSString).expandingTildeInPath
        guard !path.isEmpty else { return "Downloads" }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        return (path as NSString).abbreviatingWithTildeInPath + (exists ? "" : " (missing: using Downloads)")
    }

    /// What Settings writes for a chosen folder: empty for ~/Downloads, else the path with `~` for home.
    static func configValue(for url: URL) -> String {
        let standard = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if url.standardizedFileURL.path == standard.standardizedFileURL.path { return "" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The list lives in memory only; Paddle keeps no download history on disk, private or not.
    func track(_ download: WKDownload, isPrivate: Bool, from tab: Tab?) {
        let item = DownloadItem(download: download, isPrivate: isPrivate)
        item.browser = tab?.browser
        item.window = tab?.window ?? NSApp.keyWindow
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

    /// The address the download came from (after redirects WebKit reports the original), for Copy Link and Retry.
    static func sourceURL(of item: DownloadItem) -> URL? {
        item.download.originalRequest?.url
    }

    /// Starts the same address again as a new download from the web view that started this one (or any open tab of
    /// its window), replacing this row. Paddle keeps no partial files, so a retry starts from the beginning.
    func retry(_ item: DownloadItem) {
        // A form post (an export) isn't sent again behind the user's back.
        guard canRetry(item), let request = item.download.originalRequest,
              // Not a frozen tab's: `startDownload` raises on a suspended page.
              let webView = item.download.webView.flatMap({ Tab.owning($0)?.isSuspendedInWebKit == true ? nil : $0 })
                ?? item.browser?.allTabs.lazy.filter({ !$0.isSuspendedInWebKit }).compactMap(\.webView).first else { return }
        let browser = item.browser
        let window = item.window
        let isPrivate = item.isPrivate
        items.removeAll { $0 === item }
        webView.startDownload(using: request) { [weak self] download in
            guard let self else { return }
            self.track(download, isPrivate: isPrivate, from: nil)
            if let restarted = self.item(for: download) {
                restarted.browser = browser
                restarted.window = window
            }
        }
    }

    func canRetry(_ item: DownloadItem) -> Bool {
        guard item.state != .running, let request = item.download.originalRequest,
              ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") else { return false }
        return (request.httpMethod ?? "GET").uppercased() == "GET"
    }

    func remove(_ item: DownloadItem) {
        guard item.state != .running else { return }
        items.removeAll { $0 === item }
    }

    /// Opens a finished file the way Finder would (Gatekeeper checks it: it carries the quarantine flag).
    func open(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
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

    /// Save panel cancelled: the download never started, so it leaves no row.
    func removeUnstarted(_ item: DownloadItem) {
        items.removeAll { $0 === item }
    }

    /// Clear: the finished, failed and cancelled rows this window lists.
    func clearFinished(inPrivateWindow isPrivate: Bool) {
        items.removeAll { $0.state != .running && (isPrivate || !$0.isPrivate) }
    }

    /// The last private window closed: its finished, failed and cancelled downloads leave the list (the files
    /// stay). Running ones stay, so they can still be watched or cancelled, and leave on their own when they end.
    func forgetPrivate() {
        for item in items where item.isPrivate && item.state == .running { item.outlivedPrivateWindows = true }
        items.removeAll { $0.isPrivate && $0.state != .running }
    }

    /// A free name in ~/Downloads: "name (1).ext" when "name.ext" exists on disk or belongs to a running download.
    func uniqueDestination(for filename: String, in folder: URL = DownloadStore.folder) -> URL {
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
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "downloads")
    private weak var store: DownloadStore?

    init(store: DownloadStore) {
        self.store = store
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let store else { return nil }
        let item = store.item(for: download)
        let destination: URL
        // The window's profile may set its own folder and Ask (a private window's is the default profile's).
        let config = item?.browser?.config ?? AppModel.shared.config
        if config.askWhereToDownload {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = DownloadStore.folder(using: config)
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            // A sheet on the window the download came from, so it can't open behind it.
            let result: NSApplication.ModalResponse
            if let window = item?.window, window.isVisible {
                result = await panel.beginSheetModal(for: window)
            } else {
                NSApp.activate()
                result = await panel.begin()
            }
            guard result == .OK, let chosen = panel.url else {
                Self.log.info("save panel cancelled")
                if let item {
                    item.state = .cancelled
                    store.removeUnstarted(item)
                }
                return nil
            }
            // The panel already asked about replacing an existing file. WebKit only writes to a path that doesn't
            // exist, so the old file goes to the Trash (recoverable if this download then fails), or, when it can't,
            // the download takes a free name beside it.
            if FileManager.default.fileExists(atPath: chosen.path) {
                destination = (try? FileManager.default.trashItem(at: chosen, resultingItemURL: nil)) != nil
                    ? chosen : store.uniqueDestination(for: chosen.lastPathComponent, in: chosen.deletingLastPathComponent())
            } else {
                destination = chosen
            }
        } else {
            destination = store.uniqueDestination(for: suggestedFilename, in: DownloadStore.folder(using: config))
        }
        Self.log.info("download started")
        if let item {
            item.filename = destination.lastPathComponent
            item.destination = destination
            AccessibilityNotification.Announcement("Downloading \(item.filename)").post()
            // Chrome-style: the window it came from opens its downloads popover as the file starts.
            // Never a window of the other kind: a private download's name stays out of normal windows.
            let front = AppModel.shared.frontWindow?.model
            (item.browser ?? (front?.isPrivate == item.isPrivate ? front : nil))?.downloadsVisible = true
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        Self.log.info("download finished")
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
        Self.log.error("download failed: \(error.localizedDescription, privacy: .public)")
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
