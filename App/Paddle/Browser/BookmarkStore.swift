import AppKit
import os
import PaddleCore

/// Bookmarks in bookmarks.json: a plain file you can edit by hand (Paddle > Reload Config re-reads it, and an
/// in-app edit re-reads it first when it changed on disk, so hand edits are never overwritten).
@Observable
final class BookmarkStore {
    private(set) var tree = BookmarkTree()
    /// Set when bookmarks.json exists but can't be read. Paddle then never writes the file, so nothing is lost.
    private(set) var loadError: String?
    /// An in-app edit not yet written to disk.
    @ObservationIgnored private var dirty = false
    /// bookmarks.json's modification date and size as last read or written; nil when there was no file.
    @ObservationIgnored private var diskStamp: DiskStamp?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    private let log = Logger(subsystem: "com.walker.Paddle", category: "bookmarks")

    private struct DiskStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "Fix or remove bookmarks.json first, then Reload Config (\(reason))."
            case .nothingFound: "The file has no bookmarks in it."
            }
        }
    }

    /// Reads bookmarks.json. An in-app edit still waiting to be saved is written first, unless the file changed
    /// on disk since, in which case the hand edit wins.
    func load() {
        saveWork?.cancel()
        saveWork = nil
        if dirty, !diskChanged { saveNow() }
        dirty = false
        diskStamp = Self.stamp()
        guard FileManager.default.fileExists(atPath: Paths.bookmarks.path) else {
            tree = BookmarkTree()
            loadError = nil
            return
        }
        do {
            tree = try BookmarkTree.decode(Data(contentsOf: Paths.bookmarks))
            loadError = nil
        } catch {
            loadError = "bookmarks.json: \(PaddleConfig.describe(error))"
            log.error("\(self.loadError ?? "", privacy: .public)")
        }
    }

    /// Applies an edit, makes it undoable (Edit > Undo in the window where it happened) and saves shortly after.
    /// Refused while bookmarks.json is unreadable.
    func update(_ actionName: String, _ change: (inout BookmarkTree) -> Void) {
        if diskChanged { load() }
        guard loadError == nil else {
            NSSound.beep()
            return
        }
        let before = tree
        change(&tree)
        guard tree != before else { return }
        if let undoManager = (NSApp.keyWindow ?? NSApp.mainWindow)?.undoManager {
            registerUndo(undoManager, restoring: before, actionName)
        }
        scheduleSave()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, loadError == nil else { return }
        do {
            // Through a symlink, so a bookmarks.json linked from elsewhere stays a link.
            try tree.encoded().write(to: Paths.bookmarks.resolvingSymlinksInPath(), options: .atomic)
            dirty = false
            diskStamp = Self.stamp()
        } catch {
            log.error("bookmarks save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Favicon cache keys of every bookmarked site; their icons survive Clear History and history being off.
    var siteKeys: Set<String> {
        Set(tree.allBookmarks.compactMap { $0.url.flatMap(URL.init(string:)).flatMap(FaviconPicker.cacheKey(for:)) })
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !tree.bookmarks(for: HistoryStore.storedURL(url)).isEmpty
    }

    /// The star and Bookmarks > Bookmark This Page: adds the page to the end of the bookmarks bar, or removes
    /// every bookmark of it when it is already bookmarked (Edit > Undo puts them back). Sign-in secrets in the
    /// address (`user:password@`, `#access_token=…`) are left out, as in history.
    func toggle(url: URL, title: String) {
        let address = HistoryStore.storedURL(url)
        let existing = tree.bookmarks(for: address)
        update(existing.isEmpty ? "Add Bookmark" : "Remove Bookmark") { tree in
            if existing.isEmpty {
                let name = title.isEmpty ? (url.host() ?? address) : title
                tree.insert(Bookmark(title: name, url: address), into: .bar)
            } else {
                existing.forEach { tree.remove($0.id) }
            }
        }
    }

    /// Bookmarks > Import Bookmarks…: merges an HTML bookmarks file (Safari, Firefox, Chrome) and reports what
    /// was added.
    func importHTML(from file: URL) throws -> Int {
        if diskChanged { load() }
        if let loadError { throw Failure.unreadable(loadError) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let imported = NetscapeBookmarks.parse(text)
        guard !imported.allBookmarks.isEmpty else { throw Failure.nothingFound }
        return merge(imported, folderTitle: "Imported " + Date().formatted(date: .abbreviated, time: .omitted))
    }

    /// Import from Browser: merges a tree read straight from another browser (one Undo) and returns how many
    /// bookmarks were added. Items already in Paddle are skipped.
    func importTree(_ imported: BookmarkTree, folderTitle: String) throws -> Int {
        if diskChanged { load() }
        if let loadError { throw Failure.unreadable(loadError) }
        guard !imported.allBookmarks.isEmpty else { throw Failure.nothingFound }
        return merge(imported, folderTitle: folderTitle)
    }

    private func merge(_ imported: BookmarkTree, folderTitle: String) -> Int {
        let before = tree.allBookmarks.count
        update("Import Bookmarks") { $0.merge(imported, folderTitle: folderTitle) }
        return tree.allBookmarks.count - before
    }

    func exportHTML(to file: URL) throws {
        if diskChanged { load() }
        if let loadError { throw Failure.unreadable(loadError) }
        try Data(NetscapeBookmarks.export(tree).utf8).write(to: file, options: .atomic)
    }

    // MARK: - Private

    private var diskChanged: Bool { Self.stamp() != diskStamp }

    private static func stamp() -> DiskStamp? {
        guard let values = try? Paths.bookmarks.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return DiskStamp(modified: values.contentModificationDate, size: values.fileSize)
    }

    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Undo swaps the whole tree back; redo is registered the same way.
    private func registerUndo(_ undoManager: UndoManager, restoring old: BookmarkTree, _ actionName: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                guard store.loadError == nil else { return }
                let current = store.tree
                store.tree = old
                store.registerUndo(undoManager, restoring: current, actionName)
                store.scheduleSave()
            }
        }
        undoManager.setActionName(actionName)
    }
}

/// Bookmarks > Import Bookmarks… and Export Bookmarks….
enum BookmarkFiles {
    static func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Choose a bookmarks file exported from Safari, Firefox or Chrome (HTML)."
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let alert = NSAlert()
        do {
            let count = try AppModel.shared.bookmarks.importHTML(from: file)
            alert.messageText = count == 1 ? "Imported 1 bookmark" : "Imported \(count) bookmarks"
            alert.informativeText = "Bookmarks Bar items went to the bookmarks bar; the rest are in a new folder in the Bookmarks menu. Pages you had already bookmarked were skipped."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import bookmarks"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    static func exportFile() {
        let panel = NSSavePanel()
        panel.title = "Export Bookmarks"
        panel.nameFieldStringValue = "Paddle Bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try AppModel.shared.bookmarks.exportHTML(to: file)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't export bookmarks"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
