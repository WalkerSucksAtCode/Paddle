import Foundation
import ObjectiveC
import os
import PaddleCore

/// Logs every Objective-C exception at the moment it is thrown, with the throwing stack, before anything catches it.
/// Temporary instrumentation: AppKit and SwiftUI swallow some exceptions, and an exception unwinding through a
/// running main-actor job leaves Swift's current-executor record pointing into a dead stack frame; the crash then
/// comes later in an unrelated isolation check. Each entry goes to the log (fault level, kept on disk) and to
/// `~/Library/Logs/Paddle/exceptions.log`, which moves to `exceptions.log.1` once it passes 5 MB. Addresses in the
/// reason are written as `<url>`: a reason can quote a page's URL, a private window's included.
nonisolated enum ExceptionLog {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "exception")
    nonisolated(unsafe) private static var previous: objc_exception_preprocessor?
    /// Serializes writes: exceptions can be thrown on any thread. Recursive, because this hook sees every throw,
    /// including ones Foundation throws and catches inside the file calls below on the same thread.
    private static let lock = NSRecursiveLock()
    private static let maxBytes: UInt64 = 5 * 1024 * 1024
    private static let file: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Paddle", isDirectory: true)
        FilePermissions.createPrivateFolder(folder)
        let file = folder.appendingPathComponent("exceptions.log")
        FilePermissions.restrict(file, directory: false)
        FilePermissions.restrict(file.appendingPathExtension("1"), directory: false)
        return file
    }()

    static func install() {
        _ = file
        previous = objc_setExceptionPreprocessor { object in
            ExceptionLog.record(object)
            return ExceptionLog.previous?(object) ?? object
        }
    }

    private static func record(_ object: Any?) {
        let exception = object as? NSException
        let name = exception?.name.rawValue ?? String(describing: type(of: object))
        let reason = LogRedaction.redactURLs(exception?.reason ?? "")
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(40).joined(separator: "\n")
        let thread = Thread.isMainThread ? "main" : "background"
        log.fault("exception \(name, privacy: .public) on \(thread, privacy: .public): \(reason, privacy: .public)\n\(stack, privacy: .public)")
        append(Data("\(Date()) pid \(getpid()) \(thread) \(name): \(reason)\n\(stack)\n\n".utf8))
    }

    /// Appends one entry, first moving the file to exceptions.log.1 (replacing the older one) when it is over
    /// `maxBytes`. The `try` calls throw Swift errors rather than Objective-C exceptions, which would come back
    /// through this preprocessor while the lock is held.
    private static func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64) ?? 0
        if size > maxBytes {
            let rotated = file.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: file, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
        FilePermissions.restrict(file, directory: false)
    }
}
