import AppKit
import PaddleCore
import SwiftUI

// MARK: - Bookmarks bar

/// The row under the address bar (Bookmarks > Show Bookmarks Bar, ⇧⌘B), shown once it has a bookmark. Folders open
/// as menus.
struct BookmarksBar: View {
    let app: AppModel
    @Environment(\.chromeScale) private var scale

    var body: some View {
        let items = app.bookmarks.tree.bar
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(items) { item in
                    BookmarkBarItem(item: item)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26 * scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookmarks bar")
    }
}

private struct BookmarkBarItem: View {
    let item: Bookmark
    @Environment(\.chromeScale) private var scale

    var body: some View {
        if item.isFolder {
            Menu {
                BookmarkMenuContent(nodes: item.children ?? [])
            } label: {
                // Menu labels size to fit, so long folder names are shortened here (bookmarks cap at 160 pt).
                Label(item.title.count > 28 ? item.title.prefix(27) + "…" : item.title, systemImage: "folder")
                    .chromeFont(size: 12)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(item.title) folder")
        } else {
            Button {
                BookmarkActions.open(item, newTab: NSEvent.modifierFlags.contains(.command))
            } label: {
                HStack(spacing: 4) {
                    FaviconView(url: item.url.flatMap(URL.init(string:)), size: 12)
                    Text(item.title)
                        .chromeFont(size: 12)
                        .lineLimit(1)
                }
                .frame(maxWidth: 160 * scale)
                .padding(.horizontal, 6)
                .frame(height: 22 * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(item.url ?? "")
            .accessibilityLabel(item.title.isEmpty ? (item.url ?? "Bookmark") : item.title)
            .accessibilityHint(item.url ?? "")
            .contextMenu {
                Button("Open in New Tab") { BookmarkActions.open(item, newTab: true) }
                Divider()
                Button("Rename…") { BookmarkActions.rename(item.id) }
                Button("Delete") { BookmarkActions.delete(item.id) }
            }
        }
    }
}

/// Menu items for a folder's contents; subfolders become submenus.
private struct BookmarkMenuContent: View {
    let nodes: [Bookmark]

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                Menu(node.title) { AnyView(BookmarkMenuContent(nodes: node.children ?? [])) }
            } else {
                Button(node.title) { BookmarkActions.open(node, newTab: NSEvent.modifierFlags.contains(.command)) }
            }
        }
        if nodes.isEmpty {
            Text("Empty")
        }
    }
}

// MARK: - Actions shared by the bar, the manager and the menu

enum BookmarkActions {
    static func open(_ bookmark: Bookmark, newTab: Bool) {
        guard let string = bookmark.url, let url = URL(string: string) else { return }
        AppModel.shared.openInFrontWindow(url, newTab: newTab)
    }

    static func rename(_ id: UUID) {
        let store = AppModel.shared.bookmarks
        guard let node = store.tree.node(id),
              let title = TextPrompt.run(title: node.isFolder ? "Rename Folder" : "Rename Bookmark", initial: node.title, confirm: "Rename"),
              !title.isEmpty else { return }
        store.update("Rename") { $0.rename(id, to: title) }
    }

    static func editAddress(_ id: UUID) {
        let store = AppModel.shared.bookmarks
        guard let node = store.tree.node(id), let current = node.url,
              let text = TextPrompt.run(title: "Edit Address", initial: current, confirm: "Save"),
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return }
        store.update("Edit Address") { $0.setURL(id, to: url.absoluteString) }
    }

    /// Edit > Undo puts it back.
    static func delete(_ id: UUID) {
        let store = AppModel.shared.bookmarks
        let name = store.tree.node(id)?.isFolder == true ? "Delete Folder" : "Delete Bookmark"
        store.update(name) { $0.remove(id) }
    }

    /// New folder next to `sibling` (inside it when it is a folder), or at the end of the Bookmarks menu.
    static func newFolder(near sibling: UUID?) {
        let store = AppModel.shared.bookmarks
        guard let title = TextPrompt.run(title: "New Folder", initial: "Untitled Folder", confirm: "Create"), !title.isEmpty else { return }
        store.update("New Folder") { tree in
            if let sibling, let node = tree.node(sibling), node.isFolder, let location = tree.location(of: sibling) {
                tree.insert(.folder(title: title), into: location.section, folder: sibling)
            } else if let sibling, let location = tree.location(of: sibling) {
                tree.insert(.folder(title: title), into: location.section, folder: location.folder, at: location.index + 1)
            } else {
                tree.insert(.folder(title: title), into: .menu)
            }
        }
    }

    static func move(_ id: UUID, by offset: Int) {
        let store = AppModel.shared.bookmarks
        guard let location = store.tree.location(of: id) else { return }
        // Destination slots count positions before the move, so one step down is index + 2.
        let destination = offset < 0 ? location.index - 1 : location.index + 2
        guard destination >= 0 else { return }
        store.update("Move") { $0.move(id, to: location.section, folder: location.folder, at: destination) }
    }

    static func move(_ id: UUID, to section: BookmarkTree.Section) {
        AppModel.shared.bookmarks.update("Move") { $0.move(id, to: section, folder: nil, at: Int.max) }
    }
}

enum TextPrompt {
    static func run(title: String, message: String = "", initial: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

// MARK: - Bookmarks window

/// Bookmarks > Show Bookmarks: the bar and the menu as outlines, with search, rename, move and delete.
final class BookmarksWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: BookmarksWindowController?

    static func show() {
        let controller = shared ?? BookmarksWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookmarks"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: BookmarksView(store: AppModel.shared.bookmarks))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(NSSize(width: 640, height: 560))
        window.setFrameAutosaveName("PaddleBookmarks")
        if !window.setFrameUsingName("PaddleBookmarks") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// File > Close Tab (⌘W) closes this window; it has no tabs.
    @objc func paddleCloseTab(_ sender: Any?) { window?.performClose(sender) }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

private struct BookmarksView: View {
    let store: BookmarkStore
    @State private var query = ""
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search Bookmarks", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("New Folder") { BookmarkActions.newFolder(near: selection) }
            }
            .padding(10)
            if let error = store.loadError {
                Label(error + " Fix the file, then Paddle > Reload Config. Paddle won't change it meanwhile.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            List(selection: $selection) {
                if query.isEmpty {
                    Section("Bookmarks Bar") {
                        OutlineGroup(store.tree.bar, children: \.children) { row($0) }
                    }
                    Section("Bookmarks Menu") {
                        OutlineGroup(store.tree.menu, children: \.children) { row($0) }
                    }
                } else {
                    ForEach(store.tree.search(query)) { row($0) }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let node = store.tree.node(id) {
                    menu(for: node)
                } else {
                    Button("New Folder") { BookmarkActions.newFolder(near: nil) }
                }
            } primaryAction: { ids in
                for id in ids { if let node = store.tree.node(id) { BookmarkActions.open(node, newTab: ids.count > 1) } }
            }
            .onDeleteCommand {
                if let selection { BookmarkActions.delete(selection) }
            }
            Divider()
            Text(store.tree.allBookmarks.count == 1 ? "1 bookmark" : "\(store.tree.allBookmarks.count.formatted()) bookmarks")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private func row(_ node: Bookmark) -> some View {
        HStack(spacing: 8) {
            if node.isFolder {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 14)
            } else {
                FaviconView(url: node.url.flatMap(URL.init(string:)))
            }
            Text(node.title).lineLimit(1)
            Spacer()
            if let url = node.url {
                Text(SuggestionRanker.displayURL(url))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .tag(node.id)
        .help(node.url ?? "")
    }

    @ViewBuilder
    private func menu(for node: Bookmark) -> some View {
        if !node.isFolder {
            Button("Open") { BookmarkActions.open(node, newTab: false) }
            Button("Open in New Tab") { BookmarkActions.open(node, newTab: true) }
            Divider()
        }
        Button("Rename…") { BookmarkActions.rename(node.id) }
        if !node.isFolder {
            Button("Edit Address…") { BookmarkActions.editAddress(node.id) }
        }
        Button("New Folder") { BookmarkActions.newFolder(near: node.id) }
        Divider()
        Button("Move Up") { BookmarkActions.move(node.id, by: -1) }
        Button("Move Down") { BookmarkActions.move(node.id, by: 1) }
        if let location = store.tree.location(of: node.id) {
            if location.section == .menu || location.folder != nil {
                Button("Move to Bookmarks Bar") { BookmarkActions.move(node.id, to: .bar) }
            }
            if location.section == .bar || location.folder != nil {
                Button("Move to Bookmarks Menu") { BookmarkActions.move(node.id, to: .menu) }
            }
        }
        Divider()
        Button("Delete") { BookmarkActions.delete(node.id) }
    }
}

// MARK: - Bookmarks menu

/// Lists the bookmarks in the Bookmarks menu when it opens (Bookmarks Bar as a submenu, then the rest).
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = BookmarksMenuDelegate()
    private static let tag = 7_002

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
        let tree = AppModel.shared.bookmarks.tree
        guard !tree.bar.isEmpty || !tree.menu.isEmpty else { return }
        add(.separator(), to: menu)
        if !tree.bar.isEmpty {
            let bar = NSMenuItem(title: "Bookmarks Bar", action: nil, keyEquivalent: "")
            bar.submenu = submenu(for: tree.bar)
            add(bar, to: menu)
        }
        for node in tree.menu { add(item(for: node), to: menu) }
    }

    private func add(_ item: NSMenuItem, to menu: NSMenu) {
        item.tag = Self.tag
        menu.addItem(item)
    }

    private func submenu(for nodes: [Bookmark]) -> NSMenu {
        let menu = NSMenu()
        nodes.forEach { menu.addItem(item(for: $0)) }
        return menu
    }

    private func item(for node: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(title: String(node.title.prefix(60)), action: nil, keyEquivalent: "")
        // macOS 27 hides menu item images unless the item asks to show them.
        item.preferredImageVisibility = .visible
        if node.isFolder {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = submenu(for: node.children ?? [])
        } else {
            item.action = #selector(AppDelegate.paddleOpenBookmarkItem(_:))
            item.target = NSApp.delegate
            item.representedObject = node.url
            item.toolTip = node.url
            item.image = node.url.flatMap(URL.init(string:)).flatMap(AppModel.shared.favicons.cachedImage(for:))
        }
        return item
    }
}
