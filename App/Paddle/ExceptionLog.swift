import Foundation
import ObjectiveC
import os

/// Logs every Objective-C exception at the moment it is thrown, with the throwing stack, before anything catches it.
/// Temporary instrumentation: AppKit and SwiftUI swallow some exceptions, and an exception unwinding through a
/// running main-actor job leaves Swift's current-executor record pointing into a dead stack frame; the crash then
/// comes later in an unrelated isolation check. Each entry goes to the log (fault level, kept on disk) and to
/// `~/Library/Logs/Paddle/exceptions.log`.
nonisolated enum ExceptionLog {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "exception")
    nonisolated(unsafe) private static var previous: objc_exception_preprocessor?
    private static let file: URL = {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Paddle", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("exceptions.log")
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
        let reason = exception?.reason ?? ""
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(40).joined(separator: "\n")
        let thread = Thread.isMainThread ? "main" : "background"
        log.fault("exception \(name, privacy: .public) on \(thread, privacy: .public): \(reason, privacy: .public)\n\(stack, privacy: .public)")
        let entry = "\(Date()) pid \(getpid()) \(thread) \(name): \(reason)\n\(stack)\n\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: file)
        }
    }
}
