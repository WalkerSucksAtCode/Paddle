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

/// Watches the support folder while the Settings window is open: one directory descriptor, events debounced by
/// 300 ms. The folder rather than the file because an atomic replace (Paddle's own `.atomic` write included)
/// swaps the file out from under a file watch. In-place saves into a file that is a symlink, or that an editor
/// rewrites without renaming, don't change the folder; Settings also re-reads when its window becomes key.
/// `cancel()` (or deinit) closes the descriptor and drops any pending callback.
final class ConfigWatcher {
    private var source: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let fd = open(Paths.support.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .attrib], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    isolated deinit {
        cancel()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    /// Session saves and favicon writes land in the same folder; the stamp check in `onChange` skips those cheaply.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
