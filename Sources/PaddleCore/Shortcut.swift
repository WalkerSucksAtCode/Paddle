import Foundation

/// A keyboard shortcut written as text in `config.json`, e.g. `"cmd+shift+k"`, `"ctrl+tab"`, `"cmd+option+left"`.
public struct Shortcut: Sendable, Equatable {
    /// A single lowercase character, or a named key from `namedKeys`.
    public var key: String
    public var command = false
    public var shift = false
    public var option = false
    public var control = false

    public static let namedKeys: Set<String> = [
        "left", "right", "up", "down", "tab", "return", "escape", "delete", "space", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Parses `"cmd+shift+k"`. Returns nil for unknown modifiers, unknown key names, or no key.
    /// `"none"` parses to an empty key, meaning "remove this shortcut".
    public static func parse(_ text: String) -> Shortcut? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered == "none" { return Shortcut(key: "") }

        // Split on "+" but keep a literal "+" key ("cmd++").
        var parts = lowered.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if lowered.hasSuffix("++") || lowered == "+" { parts.append("+") }
        guard let key = parts.popLast() else { return nil }

        var shortcut = Shortcut(key: "")
        for modifier in parts {
            switch modifier {
            case "cmd", "command", "⌘": shortcut.command = true
            case "shift", "⇧": shortcut.shift = true
            case "opt", "option", "alt", "⌥": shortcut.option = true
            case "ctrl", "control", "⌃": shortcut.control = true
            default: return nil
            }
        }
        guard key.count == 1 || namedKeys.contains(key) else { return nil }
        shortcut.key = key
        return shortcut
    }
}
