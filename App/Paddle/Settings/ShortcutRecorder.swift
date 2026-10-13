import AppKit
import PaddleCore
import SwiftUI

/// A button that records the next shortcut typed: click it, or press Space or Return while it has focus, then
/// type the shortcut. Esc cancels; Delete (before or while recording) asks for no shortcut. It announces each
/// step to VoiceOver. Its key monitor exists only while recording.
struct ShortcutRecorder: NSViewRepresentable {
    /// What the button shows when not recording.
    let shortcut: Shortcut
    /// The command, for VoiceOver ("Shortcut for New Tab").
    let title: String
    /// A recorded shortcut, or one with an empty key for Delete (none).
    let onRecord: (Shortcut) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.update(shortcut: shortcut, title: title, onRecord: onRecord)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.update(shortcut: shortcut, title: title, onRecord: onRecord)
    }

    final class RecorderButton: NSButton {
        private var shortcut = Shortcut(key: "")
        private var commandTitle = ""
        private var onRecord: (Shortcut) -> Void = { _ in }
        private var monitor: Any?
        private var resignObserver: (any NSObjectProtocol)?

        private var isRecording: Bool { monitor != nil }

        init() {
            super.init(frame: .zero)
            bezelStyle = .push
            controlSize = .small
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(startRecording)
            setAccessibilityHelp("Press Space to record a new shortcut, or Delete to remove it.")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func update(shortcut: Shortcut, title: String, onRecord: @escaping (Shortcut) -> Void) {
            self.shortcut = shortcut
            commandTitle = title
            self.onRecord = onRecord
            if !isRecording { showShortcut() }
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: 120, height: super.intrinsicContentSize.height)
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard !isRecording else { return }
            switch event.charactersIgnoringModifiers {
            case " ", "\r", "\u{3}": startRecording()
            case "\u{7F}", "\u{F728}": record(Shortcut(key: ""))
            default: super.keyDown(with: event)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stopRecording(announce: nil) }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func startRecording() {
            guard !isRecording, let window else { return }
            window.makeFirstResponder(self)
            title = "Type shortcut…"
            setAccessibilityValue("Recording")
            announce("Recording. Press a shortcut, Escape to cancel, or Delete for none.")
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                // Local monitors run on the main thread, inside the app's event dispatch.
                nonisolated(unsafe) let keyEvent = event
                let swallow = MainActor.assumeIsolated { self?.handle(keyEvent) ?? false }
                return swallow ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording(announce: "Recording cancelled") }
            }
        }

        /// Every key goes to the recorder while it records, menu shortcuts included; a click elsewhere cancels.
        /// True when the event is used up here.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown else {
                if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                    stopRecording(announce: "Recording cancelled")
                }
                return false
            }
            guard event.window === window else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let bare = event.charactersIgnoringModifiers
            if flags.isEmpty, bare == "\u{1B}" {
                stopRecording(announce: "Recording cancelled")
                return true
            }
            if flags.isEmpty, bare == "\u{7F}" || bare == "\u{F728}" {
                stopRecording(announce: nil)
                record(Shortcut(key: ""))
                return true
            }
            // The unshifted key, so ⇧⌘[ records as "[" with Shift (cmd+shift+[) on any layout. Arrows, F keys and the
            // other function keys keep their `NS…FunctionKey` character: with no modifiers applied, AppKit gives
            // an arrow as a control character (→ is U+001D), which names no key.
            let isFunction = bare?.unicodeScalars.count == 1 && bare?.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
            let key = (isFunction ? bare : event.characters(byApplyingModifiers: [])) ?? bare ?? ""
            guard let recorded = Shortcut(key: key, modifiers: Shortcut.Modifiers(flags)) else {
                title = "Not a shortcut key…"
                announce("That key can't be a shortcut. Try another, or press Escape.")
                return true
            }
            // A menu shortcut needs ⌘ or ⌃; F keys may stand alone (`Shortcut.isUsableMenuShortcut`).
            guard recorded.isUsableMenuShortcut else {
                title = "Add ⌘ or ⌃…"
                announce("Add Command or Control to the key. Press Escape to cancel.")
                return true
            }
            stopRecording(announce: nil)
            record(recorded)
            return true
        }

        private func record(_ recorded: Shortcut) {
            announce(recorded.key.isEmpty ? "No shortcut for \(commandTitle)" : "Recorded \(recorded.spokenText) for \(commandTitle)")
            onRecord(recorded)
        }

        private func stopRecording(announce message: String?) {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            showShortcut()
            if let message { announce(message) }
        }

        private func showShortcut() {
            title = shortcut.displayText
            setAccessibilityLabel("Shortcut for \(commandTitle)")
            setAccessibilityValue(shortcut.key.isEmpty ? "None" : shortcut.spokenText)
        }

        private func announce(_ text: String) {
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

extension Shortcut.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}

extension Shortcut {
    /// The words VoiceOver reads: "Command Shift Left Bracket", modifiers in menu order.
    var spokenText: String {
        if key.isEmpty { return "None" }
        var words: [String] = []
        if control { words.append("Control") }
        if option { words.append("Option") }
        if shift { words.append("Shift") }
        if command { words.append("Command") }
        let names: [String: String] = [
            "left": "Left Arrow", "right": "Right Arrow", "up": "Up Arrow", "down": "Down Arrow", "tab": "Tab",
            "return": "Return", "escape": "Escape", "delete": "Delete", "space": "Space", "home": "Home", "end": "End",
            "pageup": "Page Up", "pagedown": "Page Down", "[": "Left Bracket", "]": "Right Bracket", ",": "Comma",
            ".": "Period", "/": "Slash", "\\": "Backslash", ";": "Semicolon", "'": "Quote", "`": "Grave Accent",
            "-": "Minus", "=": "Equals", "+": "Plus",
        ]
        words.append(names[key] ?? key.uppercased())
        return words.joined(separator: " ")
    }
}
