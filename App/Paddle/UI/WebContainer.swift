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
    /// The link preview's card: it shows the tab only while the tab is still the preview. After Open as Tab the fading
    /// card's view keeps being updated (SwiftUI doesn't rebuild a view on its way out) and can come after the tab's own
    /// in the same pass; taking the page then, it would leave the window with it.
    var forPreview = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let container = tab.container
        guard tab.isPreview == forPreview else { return }
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
