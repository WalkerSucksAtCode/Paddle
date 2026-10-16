import Foundation
import os
import PaddleCore
import WebKit

/// Compatibility bus: native-messaging host `ExtensionCompat.busID`, answered inside Paddle. No process
/// is launched. Any other app id, on `sendNativeMessage` or `connectNative`, gets Chrome's "Specified
/// native messaging host not found."
///
/// Requests are `{v: 1, op, args, from}`; the context comes from WebKit's delegate, never the payload.
/// Limits: 8 MB per request, 200 ops/s per extension (requests and port messages), 10 s per op.
/// Ops: `ping` (round trip + which persona). More shims later.
final class CompatBus {
    static let notFoundMessage = "Specified native messaging host not found."
    nonisolated static let errorDomain = "com.walker.Paddle.CompatBus"
    static let maxRequestBytes = 8 * 1024 * 1024
    static let opsPerSecond = 200.0
    nonisolated static let opTimeout: Duration = .seconds(10)
    /// The handshake's `ready` goes out this long after `connectUsing` returns: a message sent inside that call
    /// is lost (4c probe).
    static let readyDelay: Duration = .milliseconds(50)
    static let protocolVersion = 1
    /// Open ports one context may hold. Today's prelude opens none (it doesn't call the bus yet); the planned
    /// handshake is one port per extension page (background, popup, options, an extension tab or two), so 16 leaves
    /// room while keeping an extension that connects in a loop from piling up ports until it unloads.
    static let maxPortsPerContext = 16

    private let log = Logger(subsystem: "com.walker.Paddle", category: "compat")

    private struct Bucket {
        var tokens: Double
        var refilled: Date
    }

    /// Per context.
    private var buckets: [ObjectIdentifier: Bucket] = [:]
    /// When each context last logged going over the limit: at most one such line a second.
    private var overLimitLogged: [ObjectIdentifier: Date] = [:]
    /// Open ports per context, kept alive here (WebKit hands them over once).
    private var ports: [ObjectIdentifier: [WKWebExtension.MessagePort]] = [:]

    /// An `NSError` whose text the extension sees (WebKit prefixes "Invalid call to runtime.sendNativeMessage(). ").
    nonisolated static func error(_ text: String, code: Int = 1) -> NSError {
        NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: - Requests

    /// `runtime.sendNativeMessage(applicationID, message)`. `ext` is the loaded extension the delegate's context
    /// belongs to; nil (a context Paddle didn't load) is refused like a foreign id.
    func handle(_ message: Any, applicationID: String?, context: WKWebExtensionContext, extension ext: LoadedExtension?) async throws -> Any {
        // The budget comes first, so calls to foreign ids can't flood the log either.
        try spend(for: context, name: ext?.name ?? "a context Paddle didn't load")
        guard applicationID == ExtensionCompat.busID, let ext else {
            reject(applicationID, path: "sendNativeMessage", name: ext?.name)
            throw Self.error(Self.notFoundMessage)
        }
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw Self.error("Paddle: the request is not a JSON object")
        }
        guard data.count <= Self.maxRequestBytes else {
            log.notice("bus: \(ext.name, privacy: .public) request of \(data.count, privacy: .public) bytes refused (over 8 MB)")
            throw Self.error("Paddle: the request is larger than 8 MB")
        }
        guard let request = message as? [String: Any], (request["v"] as? NSNumber)?.intValue == Self.protocolVersion,
              let op = request["op"] as? String else {
            throw Self.error("Paddle: expected {v: 1, op, args}")
        }
        let reply = try await withTimeout(op: op, name: ext.name) { [weak self] in
            guard let self else { throw Self.error("Paddle: shutting down") }
            return try self.perform(op, request: request, ext: ext)
        }
        log.debug("bus: \(ext.name, privacy: .public) op \(op, privacy: .public) answered")
        return reply.value
    }

    /// One operation. Unknown ops are refused with their name.
    private func perform(_ op: String, request: [String: Any], ext: LoadedExtension) throws -> BusReply {
        switch op {
        case "ping":
            // An optional first argument is logged (one line, at most 600 characters): how a test extension reports
            // what it saw.
            let note = ((request["args"] as? [Any])?.first as? String).map {
                String($0.prefix(600)).replacingOccurrences(of: "\n", with: " ")
            }
            log.info("bus: \(ext.name, privacy: .public) ping answered (persona \(ext.persona.rawValue, privacy: .public))\(note.map { " note: \($0)" } ?? "", privacy: .public)")
            return BusReply([
                "v": Self.protocolVersion, "ok": true, "op": "pong", "ops": ["ping"],
                "paddle": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "persona": ext.persona.rawValue, "id": ext.id,
            ])
        default:
            log.notice("bus: \(ext.name, privacy: .public) asked for unsupported op \(op, privacy: .public)")
            throw Self.error("Paddle: unsupported operation \(op)")
        }
    }

    /// Runs `body`, failing with a timeout error after `opTimeout`; whichever comes first answers.
    private func withTimeout(op: String, name: String, _ body: @escaping @MainActor () async throws -> BusReply) async throws -> BusReply {
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BusReply, any Error>) in
            once.timer = Task { @MainActor [log] in
                try? await Task.sleep(for: Self.opTimeout)
                guard !Task.isCancelled, !once.done else { return }
                once.done = true
                once.work?.cancel()
                log.error("bus: \(name, privacy: .public) op \(op, privacy: .public) timed out after 10 s")
                continuation.resume(throwing: Self.error("Paddle: \(op) timed out", code: 2))
            }
            once.work = Task { @MainActor in
                let result: Result<BusReply, any Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                guard !once.done else { return }
                once.done = true
                once.timer?.cancel()
                continuation.resume(with: result)
            }
        }
    }

    /// The first of an operation and its timer to finish; main actor only.
    private final class Once {
        var done = false
        var timer: Task<Void, Never>?
        var work: Task<Void, Never>?
    }

    // MARK: - Ports

    /// `runtime.connectNative(applicationID)`. The id is read from the port (`applicationIdentifier`); nil or any
    /// other id throws, which disconnects the port with that error. An accepted port gets `{type: "ready"}`
    /// `readyDelay` after this returns; the prelude answers `{type: "hello", listening: [...]}`.
    func connect(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext, extension ext: LoadedExtension?) throws {
        let applicationID = port.applicationIdentifier
        let key = ObjectIdentifier(context)
        guard take(key) else {
            noteOverLimit(key, name: ext?.name ?? "a context Paddle didn't load", what: "port refused")
            throw Self.error("Paddle: too many requests", code: 3)
        }
        guard applicationID == ExtensionCompat.busID, let ext else {
            reject(applicationID, path: "connectNative", name: ext?.name)
            throw Self.error(Self.notFoundMessage)
        }
        // Ports WebKit disconnected without a handler call don't count against the cap.
        ports[key]?.removeAll { $0.isDisconnected }
        guard (ports[key]?.count ?? 0) < Self.maxPortsPerContext else {
            log.notice("bus: \(ext.name, privacy: .public) port refused (\(Self.maxPortsPerContext, privacy: .public) already open)")
            throw Self.error("Paddle: too many open ports", code: 3)
        }
        ports[key, default: []].append(port)
        let name = ext.name
        port.messageHandler = { [weak self, weak port] message, error in
            MainActor.assumeIsolated {
                guard let self, let port else { return }
                self.portMessage(message, error: error, from: name, port: port, key: key)
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ports[key]?.removeAll { $0 === port || $0.isDisconnected }
                self.log.info("bus: \(name, privacy: .public) port closed")
            }
        }
        log.info("bus: \(name, privacy: .public) port connected (\(ExtensionCompat.busID, privacy: .public)); sending ready")
        Task { @MainActor [weak port, log] in
            try? await Task.sleep(for: Self.readyDelay)
            guard let port, !port.isDisconnected else { return }
            do {
                try await port.sendMessage(["type": "ready", "v": Self.protocolVersion])
            } catch {
                log.error("bus: \(name, privacy: .public) ready not delivered: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func portMessage(_ message: Any?, error: (any Error)?, from name: String, port: WKWebExtension.MessagePort, key: ObjectIdentifier) {
        if let error {
            log.error("bus: \(name, privacy: .public) port message error: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard take(key) else {
            noteOverLimit(key, name: name, what: "port message dropped")
            return
        }
        guard let message = message as? [String: Any], let type = message["type"] as? String else {
            log.debug("bus: \(name, privacy: .public) port message without a type ignored")
            return
        }
        // The same 8 MB cap as requests, checked before any port op reads the message.
        if let data = try? JSONSerialization.data(withJSONObject: message), data.count > Self.maxRequestBytes {
            log.notice("bus: \(name, privacy: .public) port message of \(data.count, privacy: .public) bytes dropped (over 8 MB)")
            return
        }
        switch type {
        case "hello":
            let listening = (message["listening"] as? [Any])?.count ?? 0
            log.info("bus: \(name, privacy: .public) handshake ok (hello, \(listening, privacy: .public) events listened for)")
        default:
            log.debug("bus: \(name, privacy: .public) port message \(type, privacy: .public) ignored")
        }
    }

    /// Closes the extension's ports and forgets its budget (unload).
    func forget(_ context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        for port in ports[key] ?? [] where !port.isDisconnected { port.disconnect() }
        ports[key] = nil
        buckets[key] = nil
        overLimitLogged[key] = nil
    }

    // MARK: - Limits

    private func reject(_ applicationID: String?, path: String, name: String?) {
        let id = applicationID.map { String($0.prefix(80)) } ?? "nil"
        log.notice("bus: \(name ?? "a context Paddle didn't load", privacy: .public) \(path, privacy: .public) to \(id, privacy: .public) refused: \(Self.notFoundMessage, privacy: .public)")
    }

    private func spend(for context: WKWebExtensionContext, name: String) throws {
        let key = ObjectIdentifier(context)
        guard take(key) else {
            noteOverLimit(key, name: name, what: "request refused")
            throw Self.error("Paddle: too many requests")
        }
    }

    private func noteOverLimit(_ key: ObjectIdentifier, name: String, what: String) {
        let now = Date()
        if let last = overLimitLogged[key], now.timeIntervalSince(last) < 1 { return }
        overLimitLogged[key] = now
        log.notice("bus: \(name, privacy: .public) over 200 operations a second; \(what, privacy: .public) (logged at most once a second)")
    }

    /// Takes one token from the context's bucket (200 a second, bursts up to 200).
    private func take(_ key: ObjectIdentifier) -> Bool {
        let now = Date()
        var bucket = buckets[key] ?? Bucket(tokens: Self.opsPerSecond, refilled: now)
        bucket.tokens = min(Self.opsPerSecond, bucket.tokens + now.timeIntervalSince(bucket.refilled) * Self.opsPerSecond)
        bucket.refilled = now
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        buckets[key] = bucket
        return true
    }
}

/// A JSON reply crossing the timeout's task group. Built and read on the main actor only.
struct BusReply: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
