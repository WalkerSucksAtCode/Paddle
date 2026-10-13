import Foundation

/// A keyboard shortcut written as text in `config.json`, e.g. `"cmd+shift+k"`, `"ctrl+tab"`, `"cmd+option+left"`.
public struct Shortcut: Sendable, Hashable {
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
        return shortcut.canonical
    }

    /// Whether a menu can take this key without taking typing too: it needs ⌘ or ⌃ (with only Shift or ⌥, or no
    /// modifier, it would take a typed character); F keys may stand alone. True for an empty key (`"none"`).
    public var isUsableMenuShortcut: Bool {
        let isFunctionKey = key.count > 1 && key.hasPrefix("f")
        return key.isEmpty || command || control || isFunctionKey
    }

    /// Shifted US punctuation to the key it sits on, so `"{"` with Shift and `"["` with Shift are one shortcut:
    /// `MainMenu` writes its own aliases as the base key plus Shift (`"["` with ⇧⌘), and the recorder gets the
    /// shifted character from `charactersIgnoringModifiers`.
    static let shiftedPunctuation: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// True when `key` is itself a shifted character (`"+"`, `"{"`), which needs Shift to type.
    public static func isShiftedPunctuation(_ key: String) -> Bool { shiftedPunctuation[key] != nil }

    /// Self with shifted punctuation turned into its base key when Shift is set (`"{"` → `"["`), the form the
    /// validator's duplicate check, `configText` and the menu all use. Without Shift, `"+"` stays `"+"` (`"cmd++"`).
    var canonical: Shortcut {
        guard shift, let base = Shortcut.shiftedPunctuation[key] else { return self }
        var shortcut = self
        shortcut.key = base
        return shortcut
    }

    // MARK: - Text

    /// The `config.json` form, `"cmd+shift+k"`, in the order the README's examples use; `"none"` for an empty key.
    /// `parse(configText)` gives back the same shortcut.
    public var configText: String {
        if key.isEmpty { return "none" }
        var parts: [String] = []
        if command { parts.append("cmd") }
        if shift { parts.append("shift") }
        if option { parts.append("option") }
        if control { parts.append("ctrl") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The menu form, `"⇧⌘K"`, with modifiers in Apple's order (⌃⌥⇧⌘) and the key as it appears on a menu.
    /// `"None"` for an empty key.
    public var displayText: String {
        if key.isEmpty { return "None" }
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + Shortcut.displayKey(key)
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "tab": return "⇥"
        case "return": return "↩"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "space": return "Space"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        default: return key.uppercased()
        }
    }

    // MARK: - Recording

    /// Modifier flags of a key event, without AppKit so the core can be tested.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    /// Unicode scalars AppKit reports in `charactersIgnoringModifiers` for the named keys (the `NS…FunctionKey`
    /// constants), and the control characters `MainMenu` uses as key equivalents.
    private static let scalarNames: [UInt32: String] = [
        0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right",
        0xF729: "home", 0xF72B: "end", 0xF72C: "pageup", 0xF72D: "pagedown",
        0x09: "tab", 0x19: "tab", // 0x19 is NSBackTabCharacter: what Tab reports with Shift held
        0x0D: "return", 0x03: "return", 0x1B: "escape", 0x08: "delete", 0x7F: "delete", 0x20: "space",
    ]

    /// A shortcut from a recorded key event: `key` is the event's `charactersIgnoringModifiers` (a letter, digit or
    /// punctuation character, a `NS…FunctionKey` scalar, or a control character such as `"\t"`; Shift-Tab arrives
    /// as `"\u{19}"`). Shifted US punctuation is stored as its base key (`"{"` with Shift → `"["` with Shift), see
    /// `canonical`; a recorder on another layout can pass `event.characters(byApplyingModifiers: [])` instead to
    /// get the base key for that layout. Nil when the event is not a single key Paddle can name, e.g. a bare
    /// modifier, forward delete or F13.
    public init?(key: String, modifiers: Modifiers) {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        let name: String
        if let named = Shortcut.scalarNames[scalar.value] {
            name = named
        } else if (0xF704...0xF70F).contains(scalar.value) {
            name = "f\(scalar.value - 0xF704 + 1)"
        } else if scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        } else {
            name = key.lowercased()
        }
        self.init(
            key: name,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
        self = canonical
    }
}
