@testable import PaddleCore
import Testing

struct ShortcutTests {
    @Test func parses() {
        #expect(Shortcut.parse("cmd+shift+k") == Shortcut(key: "k", command: true, shift: true))
        #expect(Shortcut.parse("Ctrl+Tab") == Shortcut(key: "tab", control: true))
        #expect(Shortcut.parse("cmd+option+left") == Shortcut(key: "left", command: true, option: true))
        #expect(Shortcut.parse("cmd++") == Shortcut(key: "+", command: true))
        #expect(Shortcut.parse("none") == Shortcut(key: ""))
    }

    @Test func rejectsNonsense() {
        #expect(Shortcut.parse("hyper+k") == nil)
        #expect(Shortcut.parse("cmd+banana") == nil)
        #expect(Shortcut.parse("") == nil)
    }

    @Test func configTextRoundTripsThroughParse() {
        let samples = ["cmd+shift+k", "cmd+option+right", "ctrl+tab", "cmd++", "none", "cmd+shift+option+ctrl+f5", "a"]
        for text in samples {
            let shortcut = Shortcut.parse(text)!
            #expect(shortcut.configText == text)
            #expect(Shortcut.parse(shortcut.configText) == shortcut)
        }
        #expect(Shortcut.parse("Shift+CMD+K")?.configText == "cmd+shift+k")
    }

    @Test func displayTextUsesMenuSymbols() {
        #expect(Shortcut.parse("cmd+shift+k")?.displayText == "⇧⌘K")
        #expect(Shortcut.parse("ctrl+option+shift+cmd+a")?.displayText == "⌃⌥⇧⌘A")
        #expect(Shortcut.parse("cmd+option+right")?.displayText == "⌥⌘→")
        #expect(Shortcut.parse("ctrl+tab")?.displayText == "⌃⇥")
        #expect(Shortcut.parse("cmd+return")?.displayText == "⌘↩")
        #expect(Shortcut.parse("cmd+space")?.displayText == "⌘Space")
        #expect(Shortcut.parse("f5")?.displayText == "F5")
        #expect(Shortcut.parse("cmd++")?.displayText == "⌘+")
        #expect(Shortcut.parse("none")?.displayText == "None")
    }

    @Test func recordsKeyEvents() {
        #expect(Shortcut(key: "K", modifiers: [.command, .shift]) == Shortcut(key: "k", command: true, shift: true))
        #expect(Shortcut(key: "k", modifiers: [.command, .shift])?.configText == "cmd+shift+k")
        #expect(Shortcut(key: "\u{F703}", modifiers: [.command, .option]) == Shortcut.parse("cmd+option+right"))
        #expect(Shortcut(key: "\u{F704}", modifiers: []) == Shortcut.parse("f1"))
        #expect(Shortcut(key: "\u{F70F}", modifiers: [.control]) == Shortcut.parse("ctrl+f12"))
        #expect(Shortcut(key: "\t", modifiers: [.control]) == Shortcut.parse("ctrl+tab"))
        #expect(Shortcut(key: "\r", modifiers: [.command]) == Shortcut.parse("cmd+return"))
        #expect(Shortcut(key: "\u{1b}", modifiers: []) == Shortcut.parse("escape"))
        #expect(Shortcut(key: "\u{7f}", modifiers: [.command]) == Shortcut.parse("cmd+delete"))
        #expect(Shortcut(key: " ", modifiers: [.option]) == Shortcut.parse("option+space"))
        #expect(Shortcut(key: "\u{F72C}", modifiers: []) == Shortcut.parse("pageup"))
        #expect(Shortcut(key: "+", modifiers: [.command]) == Shortcut.parse("cmd++"))
        // Shift-Tab reports NSBackTabCharacter, not "\t": MainMenu's own previousTab default is ctrl+shift+tab.
        #expect(Shortcut(key: "\u{19}", modifiers: [.control, .shift]) == Shortcut.parse("ctrl+shift+tab"))
        #expect(Shortcut(key: "\u{19}", modifiers: [.command, .shift])?.configText == "cmd+shift+tab")
    }

    /// `charactersIgnoringModifiers` keeps Shift's effect on punctuation; the stored form is the base key plus
    /// Shift, as MainMenu writes its hidden ⇧⌘[ / ⇧⌘] aliases, so the two spellings compare equal.
    @Test func shiftedPunctuationRecordsTheBaseKey() {
        #expect(Shortcut(key: "{", modifiers: [.command, .shift]) == Shortcut(key: "[", command: true, shift: true))
        #expect(Shortcut(key: "{", modifiers: [.command, .shift])?.configText == "cmd+shift+[")
        #expect(Shortcut(key: "}", modifiers: [.command, .shift])?.displayText == "⇧⌘]")
        #expect(Shortcut(key: "+", modifiers: [.command, .shift])?.configText == "cmd+shift+=")
        #expect(Shortcut(key: "!", modifiers: [.command, .shift]) == Shortcut.parse("cmd+shift+1"))
        #expect(Shortcut.parse("cmd+shift+{") == Shortcut.parse("cmd+shift+["))
        #expect(Shortcut.parse("cmd+shift+{")?.configText == "cmd+shift+[")
        // Without Shift the character is the key: "cmd++" is still Zoom In's spelling.
        #expect(Shortcut.parse("cmd++")?.key == "+")
        #expect(Shortcut(key: "[", modifiers: [.command]) == Shortcut.parse("cmd+["))
    }

    @Test func recorderRejectsUnnameableKeys() {
        #expect(Shortcut(key: "", modifiers: [.command]) == nil)
        #expect(Shortcut(key: "ab", modifiers: [.command]) == nil)
        #expect(Shortcut(key: "\u{F710}", modifiers: []) == nil) // F13
        #expect(Shortcut(key: "\u{F728}", modifiers: []) == nil) // forward delete
        #expect(Shortcut(key: "\u{01}", modifiers: []) == nil)
    }
}
