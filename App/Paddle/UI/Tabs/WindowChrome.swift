import AppKit
import SwiftUI

/// Empty tab-strip space acts as the title bar: drag to move the window, double-click to zoom or minimize
/// (whichever System Settings > Desktop & Dock chooses). Browser windows are not movable by the window server
/// (see `BrowserWindowController.init`), so this is the only place a window drag starts.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// Calls `action` on a middle click (button 3) inside it and lets every other click through to the views around it:
/// SwiftUI has no middle-click gesture.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// Only middle-button events land here; left and right clicks fall through to the tab.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp: super.hitTest(point)
            default: nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                return super.otherMouseUp(with: event)
            }
            action()
        }
    }
}
