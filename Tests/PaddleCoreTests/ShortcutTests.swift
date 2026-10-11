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
}
