import Darwin
import Foundation
import os
import PaddleCore
import Security

/// The control bridge's listener: an owner-only Unix socket (never a TCP or UDP port) carrying one message per line
/// each way. It knows nothing about MCP. Every piece of state lives on `queue`; `ControlBridge` drives it. A
/// connection is kept only if its peer is Paddle's own signed `paddle-mcp` helper (see `PeerRequirement`).
nonisolated final class BridgeSocketServer: @unchecked Sendable {
    private struct Client {
        let fd: Int32
        let source: DispatchSourceRead
        /// Replies are written here, one client at a time, so a client that stops reading blocks only itself.
        let writer: DispatchQueue
        var splitter = BridgeLineSplitter()
        /// Lines handed to `onLine` and not yet answered with `reply`.
        var pending = 0
        /// The client finished sending: reading is suspended and it closes after its last answer.
        var halfClosed = false
    }

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    private let path: String
    private let onLine: @Sendable (Int, String) -> Void
    private let onCount: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "com.walker.Paddle.bridge")
    private let log = Logger(subsystem: "com.walker.Paddle", category: "bridge")
    private var listener: DispatchSourceRead?
    /// The socket file this server made, so `stop` never removes one another process put there since.
    private var boundInode: ino_t?
    private var clients: [Int: Client] = [:]
    private var nextID = 1

    /// `onLine` gets each message line with its client's number, and each line must be answered with exactly one
    /// `reply`; `onCount` gets the number of connected clients after each change. Both are called on the server's queue.
    init(path: String, onLine: @escaping @Sendable (Int, String) -> Void, onCount: @escaping @Sendable (Int) -> Void) {
        self.path = path
        self.onLine = onLine
        self.onCount = onCount
    }

    /// Creates the socket (mode 0600, in a folder only the user can enter) and starts accepting connections.
    func start() throws {
        try queue.sync { try open() }
    }

    /// Drops every client, closes the listener and removes the socket file.
    func stop() {
        queue.sync {
            for id in Array(clients.keys) { drop(id) }
            listener?.cancel()
            listener = nil
            var info = stat()
            if let boundInode, lstat(path, &info) == 0, info.st_ino == boundInode { unlink(path) }
            boundInode = nil
        }
    }

    /// Drops every client; the listener stays open, so a session can connect again.
    func disconnectAll() {
        queue.async {
            for id in Array(self.clients.keys) { self.drop(id) }
        }
    }

    /// Answers one line `onLine` handed over: writes `line` and a newline (nothing for a notification) to client
    /// `id`, if it is still connected. A client that has finished sending is closed after its last answer.
    func reply(_ line: String?, to id: Int) {
        queue.async {
            guard var client = self.clients[id] else { return }
            client.pending -= 1
            self.clients[id] = client
            defer { if client.halfClosed, client.pending <= 0 { self.drop(id, afterReplies: true) } }
            guard let line else { return }
            self.write(line, to: client, id: id)
        }
    }

    /// Queues `line` and a newline on the client's writer. The socket has a send timeout, so a client that stops
    /// reading is dropped after `writeTimeoutSeconds` instead of parking the writer for good.
    private func write(_ line: String, to client: Client, id: Int) {
        let bytes = Array((line + "\n").utf8)
        let fd = client.fd
        client.writer.async { [weak self] in
            let ok = bytes.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
            if !ok {
                self?.queue.async {
                    self?.log.error("control bridge client stopped reading or its write failed; dropped")
                    self?.drop(id)
                }
            }
        }
    }

    // MARK: - Listening

    private func open() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try Self.prepareFolder(folder)

        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw StartError(description: "\(path) exists and isn't Paddle's socket")
            }
            guard !Self.isListening(path) else {
                throw StartError(description: "another copy of Paddle is already listening on the control socket")
            }
            unlink(path)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StartError(description: "the socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.withCString { strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(description: "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // The process umask is left alone (other threads create files meanwhile): the folder is owner-only, so no
        // one else can reach the socket before it is made 0600, which happens before it listens.
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw StartError(description: "bind: \(String(cString: strerror(error)))")
        }
        if lstat(path, &info) == 0 { boundInode = info.st_ino }
        guard chmod(path, 0o600) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            boundInode = nil
            throw StartError(description: "chmod: \(String(cString: strerror(error)))")
        }

        guard listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            boundInode = nil
            throw StartError(description: "listen: \(String(cString: strerror(error)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        log.info("control bridge listening at \(self.path, privacy: .private)")
    }

    /// The socket's folder must be a folder the user owns; group and other access is removed.
    private static func prepareFolder(_ folder: String) throws {
        var info = stat()
        if stat(folder, &info) != 0 {
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST, stat(folder, &info) == 0 else {
                throw StartError(description: "can't create \(folder)")
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw StartError(description: "\(folder) isn't a folder owned by you")
        }
        if info.st_mode & 0o077 != 0, chmod(folder, 0o700) != 0 {
            throw StartError(description: "can't make \(folder) owner-only")
        }
    }

    /// Whether something already accepts connections at `path` (another running copy).
    private static func isListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.withCString { strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    // MARK: - Clients

    private func acceptAll(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 { return }
            // Only Paddle's own signed helper, run by the user; the folder and mode already keep others out.
            if case .refuse(let reason) = Self.checkPeer(fd) {
                close(fd)
                log.error("control bridge refused a connection: \(reason, privacy: .public)")
                continue
            }
            guard clients.count < BridgeLimits.maxClients else {
                close(fd)
                log.error("control bridge refused a connection: \(BridgeLimits.maxClients, privacy: .public) clients are already connected")
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: BridgeLimits.writeTimeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)

            let id = nextID
            nextID += 1
            let writer = DispatchQueue(label: "com.walker.Paddle.bridge.client")
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(from: id) }
            // Closed after any reply already queued for it, so the number is never reused under a pending write.
            source.setCancelHandler { writer.async { close(fd) } }
            clients[id] = Client(fd: fd, source: source, writer: writer)
            source.resume()
            log.info("control bridge client connected (\(self.clients.count, privacy: .public) connected)")
            onCount(clients.count)
        }
    }

    /// Whether the process on the other end of `fd` is the same user's `paddle-mcp` helper signed by Paddle's team.
    /// Any failure refuses. The log line a refusal produces holds no URLs.
    private static func checkPeer(_ fd: Int32) -> PeerRequirement.Verdict {
        var uid: uid_t = 0
        var gid: gid_t = 0
        let peerUID: UInt32? = getpeereid(fd, &uid, &gid) == 0 ? uid : nil

        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let peerPID: Int32? = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil

        // The signature is only worth checking for a same-user peer with a known pid.
        var valid: Bool?
        if peerUID == getuid(), let peerPID, peerPID > 0 {
            valid = signatureIsValid(pid: peerPID)
        }
        return PeerRequirement.verdict(peerUID: peerUID, ownUID: getuid(), peerPID: peerPID, signatureValid: valid)
    }

    /// True/false when the Security framework answered, nil on any error that isn't a plain "doesn't satisfy".
    private static func signatureIsValid(pid: pid_t) -> Bool? {
        guard let text = PeerRequirement.requirementString() else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: Int(pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        let status = SecCodeCheckValidity(code, [], requirement)
        if status == errSecSuccess { return true }
        // Not signed at all, or signed by someone else: a plain refusal. Anything else is also a refusal (fail closed).
        return false
    }

    private func read(from id: Int) {
        guard let fd = clients[id]?.fd else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        if count == 0, (clients[id]?.pending ?? 0) > 0 {
            // The client finished sending (the helper half-closes when its stdin ends): stop reading, and close
            // once the answers still being worked on are written.
            clients[id]?.source.suspend()
            clients[id]?.halfClosed = true
            return
        }
        guard count > 0 else {
            drop(id)
            return
        }
        // Mutated in place in the dictionary, so the splitter's buffer is never copied.
        guard let output = clients[id]?.splitter.append(bytes[0..<count]) else { return }
        if output.overflow {
            log.error("control bridge client sent an over-long message; dropped")
            drop(id)
            return
        }
        for line in output.lines {
            guard let client = clients[id] else { return }
            if client.pending >= BridgeLimits.maxPendingCalls {
                if let busy = BridgeLimits.busyReply(forLine: line) { write(busy, to: client, id: id) }
                continue
            }
            clients[id]?.pending += 1
            onLine(id, line)
        }
    }

    /// Forgets client `id`. By default the connection is cut at once; `afterReplies` closes it once the answers
    /// already queued for it are written (the cancel handler closes it on the writer queue).
    private func drop(_ id: Int, afterReplies: Bool = false) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if !afterReplies { shutdown(client.fd, SHUT_RDWR) }
        // A suspended source must be resumed for its cancel handler to run.
        if client.halfClosed { client.source.resume() }
        client.source.cancel()
        log.info("control bridge client disconnected (\(self.clients.count, privacy: .public) connected)")
        onCount(clients.count)
    }
}
