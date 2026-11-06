import Darwin
import Foundation

/// What a `config.json` on disk looked like: enough to tell a new write from one already seen without reading the
/// bytes. An atomic replace (Paddle's own writes, most editors) changes the inode; an in-place save changes the
/// modification time or size.
struct ConfigStamp: Equatable {
    var inode: UInt64
    var size: Int64
    var modified: timespec

    /// The stamp of the file `url` points to (symlinks followed); nil when it is missing.
    init?(_ url: URL = Paths.config) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
    }

    static func == (a: ConfigStamp, b: ConfigStamp) -> Bool {
        a.inode == b.inode && a.size == b.size
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
    }
}

/// Watches config.json while a Settings tab shows; both watches debounce 300 ms:
/// - the support folder, for atomic replaces (Paddle's `.atomic` write, most editors), which swap
///   the file out from under a file watch;
/// - config.json itself (the symlink target) for write, extend and attribute changes — VS Code and
///   Cursor save in place and don't touch the folder. After a delete or rename the descriptor
///   follows the old file, so it is re-opened on whatever the path holds now.
/// Settings also re-reads when its window becomes key. `cancel()` / deinit close both descriptors
/// and drop any pending callback.
final class ConfigWatcher {
    private var folder: (any DispatchSourceFileSystemObject)?
    private var file: (any DispatchSourceFileSystemObject)?
    /// The inode `file` watches, to notice the path now naming a different file.
    private var fileInode: UInt64?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        folder = Self.watch(Paths.support.path, events: [.write, .rename, .delete, .link, .attrib]) { [weak self] _ in
            self?.folderChanged()
        }
        watchFile()
    }

    isolated deinit {
        cancel()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        folder?.cancel()
        folder = nil
        file?.cancel()
        file = nil
        fileInode = nil
    }

    /// (Re)opens the file watch on what config.json names now; a missing file leaves it off until the folder
    /// watch sees one appear.
    private func watchFile() {
        file?.cancel()
        file = nil
        let url = Paths.config.resolvingSymlinksInPath()
        fileInode = ConfigStamp(url)?.inode
        guard fileInode != nil else { return }
        file = Self.watch(url.path, events: [.write, .extend, .attrib, .delete, .rename, .revoke]) { [weak self] events in
            self?.fileChanged(events)
        }
        if file == nil { fileInode = nil }
    }

    private func fileChanged(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) { watchFile() }
        schedule()
    }

    /// Session saves and favicon writes land in the same folder; an event that leaves config.json's stamp —
    /// inode, size, mtime — exactly as it was is dropped here instead of costing a debounced onChange that
    /// reads the file and does nothing. A real in-place write changes mtime, so it still gets through, and the
    /// duplicate event the file watch sends for the same write dedupes through `lastSeenStamp`.
    private func folderChanged() {
        guard let stamp = ConfigStamp(Paths.config.resolvingSymlinksInPath()) else {
            schedule()  // gone: let onChange handle it (a reload creates it again)
            return
        }
        if stamp.inode != fileInode {
            watchFile()
            schedule()
            return
        }
        if stamp != lastSeenStamp {
            lastSeenStamp = stamp
            schedule()
        }
    }

    /// The config stamp the last scheduled onChange saw.
    private var lastSeenStamp: ConfigStamp?

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// An event-only descriptor on `path` delivering `events` on the main queue; the descriptor closes on cancel.
    private static func watch(
        _ path: String, events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak source] in
            guard let events = source?.data else { return }
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
