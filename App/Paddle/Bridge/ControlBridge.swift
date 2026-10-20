import AppKit
import Foundation
import os
import PaddleCore
import WebKit

/// The control bridge (`controlBridge` in config.json): a local MCP server Claude sessions reach through the
/// `paddle-mcp` helper and an owner-only Unix socket (`BridgeSocketServer`). Private windows are invisible to it.
/// The tools are in `ControlBridge+Tools.swift`.
@Observable
final class ControlBridge {
    static let shared = ControlBridge()

    /// One tool call, for Settings > Advanced: no page content, only the tool and a short summary of its arguments.
    struct AuditEntry: Identifiable {
        let id = UUID()
        let date: Date
        let tool: String
        let summary: String
        let ok: Bool
    }

    static let auditLimit = 50

    private(set) var clientCount = 0
    private(set) var audit: [AuditEntry] = []
    /// Why the socket couldn't be opened, while the switch is on.
    private(set) var startError: String?

    @ObservationIgnored private var server: BridgeSocketServer?
    /// Which `start` the current server came from. A line waiting to run when the switch went off and on again belongs
    /// to the old server, whose client numbers the new one reuses; it is dropped, not answered to someone else.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let core = MCPServerCore(serverVersion: ControlBridge.appVersion)
    @ObservationIgnored let log = Logger(subsystem: "com.walker.Paddle", category: "bridge")
    /// The content world bridge scripts run in: never the page's own, and not the one user scripts or extensions use.
    @ObservationIgnored let world = WKContentWorld.world(name: "PaddleControlBridge")

    var isListening: Bool { server != nil }

    /// "0.1.0 (1)": the running app's version and build.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/paddle-mcp").path
    }

    /// The command that adds the bridge to Claude Code, quoting the path when it needs it.
    static var setupCommand: String {
        let path = helperPath
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return "claude mcp add paddle -- " + (plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'")
    }

    /// Opens or closes the socket to match the switch. At launch, and whenever `controlBridge` changes.
    func update(enabled: Bool) {
        if enabled, server == nil {
            start()
        } else if !enabled {
            stop()
            startError = nil
        }
    }

    /// Closes the socket and every client and removes the socket file (switch off, or quit).
    func stop() {
        guard let server else { return }
        server.stop()
        self.server = nil
        clientCount = 0
        log.info("control bridge off")
    }

    /// The toolbar's Disconnect: drops every connected session; the bridge stays on.
    func disconnectAll() {
        server?.disconnectAll()
    }

    private func start() {
        generation += 1
        let generation = generation
        let server = BridgeSocketServer(
            path: Paths.controlSocket.path,
            onLine: { client, line in
                Task { @MainActor in await ControlBridge.shared.received(line, from: client, generation: generation) }
            },
            onCount: { count in
                Task { @MainActor in ControlBridge.shared.clientCount = count }
            }
        )
        do {
            try server.start()
            self.server = server
            startError = nil
        } catch {
            startError = "\(error)"
            log.error("control bridge couldn't start: \(String(describing: error), privacy: .public)")
        }
    }

    private func received(_ line: String, from client: Int, generation: Int) async {
        guard let server, generation == self.generation else { return }
        // A nonisolated closure that hops to the main actor, so it can be handed to the core.
        let reply = await core.handle(line) { @Sendable name, arguments in
            await ControlBridge.shared.call(name, arguments)
        }
        // Always answered, even with nothing (a notification), so the server knows when a finished client can close.
        server.reply(reply, to: client)
    }

    /// Runs one tool and records it in the audit.
    func call(_ name: String, _ arguments: JSONValue) async -> MCPToolResult {
        let args = arguments.objectValue ?? [:]
        let result: MCPToolResult
        do {
            result = try await perform(name, args)
        } catch let error as BridgeToolError {
            result = .error(error.message)
        } catch {
            result = .error(error.localizedDescription)
        }
        let summary = Self.summary(of: args)
        audit.append(AuditEntry(date: Date(), tool: name, summary: summary, ok: !result.isError))
        if audit.count > Self.auditLimit { audit.removeFirst(audit.count - Self.auditLimit) }
        log.info("tool \(name, privacy: .public) \(result.isError ? "failed" : "ok", privacy: .public): \(summary, privacy: .private)")
        return result
    }

    /// A short, content-free description of a call's arguments: ids shortened, an address's host only, a
    /// script's length, the config keys changed.
    static func summary(of args: [String: JSONValue]) -> String {
        var parts: [String] = []
        if case .string(let tab)? = args["tab"] { parts.append("tab \(tab.prefix(8))") }
        if case .string(let window)? = args["window"] { parts.append("window \(window.prefix(8))") }
        if case .string(let text)? = args["url"] {
            let url = URL(string: text)
            parts.append("url \(url?.host() ?? url?.scheme ?? "?")")
        }
        if case .string(let name)? = args["name"] { parts.append(name) }
        if case .object(let changes)? = args["changes"] { parts.append("keys " + changes.keys.sorted().joined(separator: ", ")) }
        if case .string(let script)? = args["script"] { parts.append("script, \(script.count) characters") }
        return parts.joined(separator: "; ")
    }
}

/// A tool call that failed in a way the model should read (an unknown tab, a refused key).
nonisolated struct BridgeToolError: Error {
    let message: String

    init(_ message: String) { self.message = message }
}
