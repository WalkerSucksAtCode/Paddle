import AppKit
import SwiftUI
import WebKit

/// Shows the selected tab's container (its web view, plus a docked Web Inspector). Other tabs' containers are
/// detached from the window, which lets WebKit throttle their timers and stop rendering them.
struct WebContainer: NSViewRepresentable {
    let tab: Tab
    /// Changes whenever the tab's web view is created or dropped.
    let generation: Int
    /// False for the unfocused side of a split: attaching it leaves the keyboard where it is.
    var takesKeyboard = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let container = tab.container
        if view.subviews.count == 1, view.subviews.first === container {
            if generation != context.coordinator.generation, takesKeyboard { tab.browser?.controller?.focusWebView() }
            context.coordinator.generation = generation
            return
        }
        view.subviews.forEach { $0.removeFromSuperview() }
        container.frame = view.bounds
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)
        context.coordinator.generation = generation
        if takesKeyboard { tab.browser?.controller?.focusWebView() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var generation = -1
    }
}
