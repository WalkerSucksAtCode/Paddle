import Foundation

// paddle-mcp: relays bytes between stdin/stdout (an MCP client such as Claude Code) and Paddle's control socket.
// It does not interpret MCP. Foundation only, so it can be signed and shipped inside the app on its own.

/// The same rule as `Paths.controlSocket` in the app: the socket sits in the support folder's bridge/ unless that path would
/// not fit `sun_path` (104 bytes), then in `<temp dir>/paddle-<uid>/`.
func controlSocketPath() -> String {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Paddle", directoryHint: .isDirectory)
    let inSupport = support.appending(path: "bridge", directoryHint: .isDirectory).appending(path: "control.sock").path
    if inSupport.utf8.count < 104 { return inSupport }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "paddle-\(getuid())", directoryHint: .isDirectory).appending(path: "control.sock").path
}

func fail(_ message: String) -> Never {
    let line = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"\(message)\"}}\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    exit(1)
}

func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if n < 0 { if errno == EINTR { continue }; return false }
        offset += n
    }
    return true
}

signal(SIGPIPE, SIG_IGN)

let notRunning = "Paddle is not running, or the control bridge is off. Turn it on in Paddle > Settings > Advanced."
let path = controlSocketPath()

// The socket must be ours: a socket another user could have planted is not connected to.
var info = stat()
guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { fail(notRunning) }

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else { fail(notRunning) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: address.sun_path)
guard path.utf8.count < capacity else { fail(notRunning) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    _ = path.withCString { strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { fail(notRunning) }

// stdin -> socket on a thread; socket -> stdout here. Stdin ending half-closes the socket and lets the answers drain.
let upstream = Thread {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        let sent = buffer.withUnsafeBytes { writeAll(sock, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        if !sent { break }
    }
    shutdown(sock, SHUT_WR)
}
upstream.start()

var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(sock, &buffer, buffer.count)
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { break }
    let sent = buffer.withUnsafeBytes { writeAll(STDOUT_FILENO, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
    if !sent { break }
}
exit(0)
