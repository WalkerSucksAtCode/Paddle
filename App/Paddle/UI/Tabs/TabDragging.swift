import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab being dragged inside Paddle (declared in Info.plist). Not text, so a web page under the pointer can't
    /// take the drop: a tab let go outside every tab strip becomes a window, as in Firefox and Chrome.
    nonisolated static let paddleTab = UTType(exportedAs: "com.walker.paddle.tab")
}

nonisolated struct TabDragPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .paddleTab)
    }
}

extension TabDragPayload {
    /// The dragged tab, in whichever window it is.
    @MainActor var tab: Tab? { AppModel.shared.allTabs.first { $0.id == id } }
}

/// `.draggable` only while the tab is not being renamed, so a drag inside the title field selects text. A drag no
/// tab strip took (dropped on a page, the desktop, another app) tears the tab off into a new window under the pointer.
struct TabDrag: ViewModifier {
    let tab: Tab
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(TabDragPayload(id: tab.id))
                .onDragSessionUpdated { session in
                    guard case .ended(let operation) = session.phase, operation == .cancel || operation == .forbidden else { return }
                    // Escape cancels a drag; only a real drop elsewhere tears off.
                    if let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp { return }
                    // A tab strip that refused the drop (onto itself, across the pin boundary, another profile) is
                    // still a drop on a strip, not a tear-off.
                    if TabDrop.consumeHandledDrop() { return }
                    TabDrop.tearOff(tab, at: NSEvent.mouseLocation)
                }
        } else {
            content
        }
    }
}

/// Drops of a dragged tab: onto a tab, onto a group label, or onto the strip's empty space, from this window or another.
@MainActor
enum TabDrop {
    /// When a tab strip's drop handler last ran, accepted or not.
    private static var lastHandled: Date?

    static func consumeHandledDrop() -> Bool {
        defer { lastHandled = nil }
        return lastHandled.map { Date().timeIntervalSince($0) < 2 } ?? false
    }

    /// Onto `target`: before or after it as `BrowserModel.move` does within a window; from another window it lands at
    /// `target`'s place and joins its group.
    static func drop(_ payloads: [TabDragPayload], onto target: Tab, in model: BrowserModel) -> Bool {
        lastHandled = Date()
        guard let dragged = payloads.first?.tab, dragged !== target else { return false }
        if dragged.browser === model { return model.move(dragged, onto: target) }
        guard let controller = model.controller, model.canAccept(dragged), dragged.isPinned == target.isPinned,
              let index = model.tabs.firstIndex(where: { $0 === target }) else { return false }
        AppModel.shared.move(dragged, to: controller, at: index, select: true)
        dragged.groupID = target.groupID
        model.normalizeGroups()
        return true
    }

    /// Onto empty strip space: the end of the window's tabs.
    static func append(_ payloads: [TabDragPayload], to model: BrowserModel) -> Bool {
        lastHandled = Date()
        guard let dragged = payloads.first?.tab, let controller = model.controller, model.canAccept(dragged) else { return false }
        // Within a window `place` takes an index over every space's tabs; across windows `adopt` takes one in the
        // active space. Each clamps, so a count past either end means "last".
        let index = dragged.browser === model ? model.allTabs.count : model.tabs.count
        AppModel.shared.move(dragged, to: controller, at: index, select: true)
        if dragged.browser === model {
            dragged.groupID = nil
            model.normalizeGroups()
        }
        return true
    }

    /// Onto a group label: into that group (moved to this window first when it comes from another).
    static func add(_ payloads: [TabDragPayload], to group: TabGroup, in model: BrowserModel) -> Bool {
        lastHandled = Date()
        guard let dragged = payloads.first?.tab, !dragged.isPinned else { return false }
        if dragged.browser !== model {
            guard let controller = model.controller, model.canAccept(dragged) else { return false }
            AppModel.shared.move(dragged, to: controller, at: model.tabs.count, select: true)
        }
        model.add(dragged, to: group)
        return true
    }

    /// A new window holding `tab`, its top left near `point` (screen coordinates). The only tab of its window moves the
    /// window instead, as in Chrome.
    static func tearOff(_ tab: Tab, at point: NSPoint) {
        guard let source = tab.browser else { return }
        let topLeft = NSPoint(x: point.x - 60, y: point.y + 14)
        if source.allTabs.count == 1 {
            source.controller?.window?.setFrameTopLeftPoint(topLeft)
            return
        }
        let controller = AppModel.shared.openWindow(isPrivate: source.isPrivate, profile: source.profileID, moving: [tab])
        controller.window?.setFrameTopLeftPoint(topLeft)
        controller.model.select(tab)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
