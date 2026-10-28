import Foundation

/// Which processes may talk to the control bridge: only the user's own, and only Paddle's signed `paddle-mcp` helper.
/// The Security-framework calls live in the app; this holds the requirement text and the accept/refuse decision.
public enum PeerRequirement {
    /// The helper's signing identifier (`codesign -dv` shows `Identifier=paddle-mcp`).
    public static let helperIdentifier = "paddle-mcp"
    /// Paddle's team: both the Developer ID helper (Release) and an Apple Development one (Debug) carry it.
    public static let teamID = "VB3UP263YT"

    public enum Verdict: Equatable, Sendable {
        case accept
        case refuse(String)
    }

    /// A code-signing requirement string for `identifier` signed by team `team`, chained to Apple's anchor, or nil if
    /// either has a character that could change the requirement's meaning (only letters, digits, dot, dash and
    /// underscore are taken).
    public static func requirementString(identifier: String = helperIdentifier, team: String = teamID) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        func clean(_ text: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        guard clean(identifier), clean(team) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The decision for one connection. Each input is nil when it couldn't be determined, which refuses: the check
    /// fails closed. `signatureValid` is the result of validating the peer's code against `requirementString`.
    public static func verdict(peerUID: UInt32?, ownUID: UInt32, peerPID: Int32?, signatureValid: Bool?) -> Verdict {
        guard let peerUID else { return .refuse("the peer's user couldn't be read") }
        guard peerUID == ownUID else { return .refuse("the peer belongs to another user") }
        guard let peerPID, peerPID > 0 else { return .refuse("the peer's process couldn't be read") }
        guard let signatureValid else { return .refuse("the peer's signature couldn't be checked") }
        guard signatureValid else { return .refuse("the peer isn't Paddle's signed helper") }
        return .accept
    }
}
