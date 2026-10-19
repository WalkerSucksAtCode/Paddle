import AppKit
import PaddleCore
import SwiftUI

/// The page of an empty tab: pinned sites, an optional Frequently visited row and a link to Settings > General.
/// Pinned sites come from `app.newTab`; the frequent row is shown from the last result at once and re-queried off the main thread on appear and when the store or config changes.
struct NewTabPage: View {
    let model: BrowserModel
    let app: AppModel
    @State private var frequent: [HistoryEntry] = []
    @State private var frequentTask: Task<Void, Never>?
    @State private var adding = false
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeTheme) private var theme

    private var showsFrequent: Bool { model.config.newTabFrequentSites && !model.isPrivate }
    private var showsNotifications: Bool { model.config.newTabNotifications && !model.isPrivate }
    private var inbox: NotificationInbox { .shared }
    /// The inbox without the sites hidden from New Tab (`newTabHiddenNotifications`).
    private var shownNotifications: [NotificationInbox.Entry] {
        let hidden = Set(model.config.newTabHiddenNotifications.map { $0.lowercased() })
        return inbox.entries.filter { !hidden.contains($0.host.lowercased()) }
    }
    private var feeds: FeedStore { .shared }

    var body: some View {
        let sites = app.newTab.sites
        VStack(spacing: 0) {
            // Centred while it fits; the News and Notifications sections can make it scroll.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)
                        VStack(spacing: 22) {
                            Text("Paddle")
                                .chromeFont(size: 22, weight: .semibold, design: .rounded)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: TileMetrics.width * scale, maximum: 120 * scale), spacing: 12)], spacing: 12) {
                                ForEach(sites) { site in
                                    PinnedTile(site: site, model: model, app: app)
                                }
                                if sites.count < NewTabSites.maxSites {
                                    AddTile(adding: $adding, app: app)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Pinned sites")
                            if showsFrequent, !frequent.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Frequently visited")
                                        .chromeFont(size: 11, weight: .semibold)
                                        .foregroundStyle(.secondary)
                                        .accessibilityAddTraits(.isHeader)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: TileMetrics.width * scale, maximum: 120 * scale), spacing: 12)], alignment: .leading, spacing: 12) {
                                        ForEach(frequent) { entry in
                                            FrequentTile(entry: entry, model: model, app: app)
                                        }
                                    }
                                    .accessibilityElement(children: .contain)
                                    .accessibilityLabel("Frequently visited")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if showsNotifications, !shownNotifications.isEmpty {
                                NotificationsSection(inbox: inbox, entries: shownNotifications, hidden: model.config.newTabHiddenNotifications)
                            }
                            if !model.config.newTabFeeds.isEmpty, !model.isPrivate {
                                NewsSection(feeds: feeds, model: model)
                            }
                        }
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 24)
                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
            // Settings > General, whose New Tab section has this page's options (feeds, frequent sites, notifications).
            Button("Customize Paddle…") {
                model.showSettings(pane: .general)
            }
            .buttonStyle(.link)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme?.newTabBackground ?? Color(nsColor: .textBackgroundColor))
        .chromeText(enabled: theme?.newTabBackground != nil)
        .onAppear {
            refreshFrequent()
            if !model.isPrivate { feeds.refreshIfDue(feeds: model.config.newTabFeeds) }
        }
        .onChange(of: model.config.newTabFeeds) { _, new in if !model.isPrivate { feeds.refreshIfDue(feeds: new) } }
        .onDisappear { frequentTask?.cancel() }
        .onChange(of: app.newTab.sites) { refreshFrequent() }
        .onChange(of: app.newTab.hiddenFrequent) { refreshFrequent() }
        .onChange(of: model.config.newTabFrequentSites) { refreshFrequent() }
    }

    /// Shows the cached row now, then replaces it with a fresh query's result. A newer refresh cancels the older one;
    /// a result only lands while this page still belongs to the profile it was asked for.
    private func refreshFrequent() {
        frequentTask?.cancel()
        guard showsFrequent else {
            frequent = []
            return
        }
        let profile = model.profileID
        frequent = app.newTab.cachedFrequentSites(profile: profile)
        frequentTask = Task {
            guard let found = await app.newTab.loadFrequentSites(limit: 8, profile: profile),
                  !Task.isCancelled, model.profileID == profile, showsFrequent else { return }
            frequent = found
        }
    }
}

// MARK: - Notifications and News

/// This run's website notifications, newest first: the site, the title and a line of the body. A click shows the
/// site's tab as clicking the notification does; right-click hides the site from New Tab.
private struct NotificationsSection: View {
    let inbox: NotificationInbox
    let entries: [NotificationInbox.Entry]
    let hidden: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications")
                    .chromeFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") { inbox.clear() }
                    .buttonStyle(.link)
                    .chromeFont(size: 11)
            }
            VStack(spacing: 0) {
                ForEach(entries.prefix(8)) { entry in
                    Button {
                        WebsiteNotifications.shared.showSite(origin: entry.origin)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? entry.host : entry.title)
                                    .chromeFont(size: 13, weight: .medium)
                                    .lineLimit(1)
                                if !entry.body.isEmpty {
                                    Text(entry.body).chromeFont(size: 12).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text("\(entry.host) · \(entry.date.formatted(.relative(presentation: .named)))")
                                .chromeFont(size: 11)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(entry.host)")
                    .contextMenu {
                        Button("Hide \(entry.host) from New Tab") {
                            Task { await AppModel.shared.writeConfigKey(.newTabHiddenNotifications, .array((hidden + [entry.host]).map { .string($0) })) }
                        }
                        Button("Remove This One") { inbox.remove(entry) }
                    }
                    if entry != entries.prefix(8).last { Divider().padding(.leading, 12) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The newest stories of `newTabFeeds`, as cards two or three to a row. A click opens the story in this tab.
private struct NewsSection: View {
    let feeds: FeedStore
    let model: BrowserModel
    @Environment(\.chromeScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("News")
                    .chromeFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if feeds.refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Updating") }
                Spacer()
            }
            if feeds.items.isEmpty {
                Text(feeds.refreshing ? "Loading stories…" : feeds.problems.isEmpty ? "No stories yet." : "The feeds couldn't be read. See Settings > General > New Tab.")
                    .chromeFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210 * scale), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(feeds.items.prefix(12)) { item in
                    Button {
                        model.selectedTab?.load(item.link)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let image = item.image {
                                FeedThumbnail(url: image, feeds: feeds)
                                    .frame(height: 112 * scale)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(.bottom, 2)
                            }
                            Text(item.title)
                                .chromeFont(size: 13, weight: .medium)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 0)
                            Text([item.source, item.published.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                                .chromeFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 92 * scale, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help(item.link.absoluteString)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A story's picture, filling its frame (cropped), loaded when the card appears; a plain tint until then or if it
/// can't be loaded.
private struct FeedThumbnail: View {
    let url: URL
    let feeds: FeedStore
    @State private var image: NSImage?

    var body: some View {
        Color.primary.opacity(0.06)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) { image = await feeds.image(for: url, maxPixel: 640) }
    }
}

// MARK: - Tiles

private enum TileMetrics {
    static let width: CGFloat = 104
    static let height: CGFloat = 92
}

/// The look shared by every tile: size, fill by hover and keyboard focus, and the icon over a one-line title.
private struct TileFace: View {
    let title: String
    let url: URL?
    let host: String
    var focused: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chromeScale) private var scale

    var body: some View {
        VStack(spacing: 6) {
            icon
                .frame(width: 40 * scale, height: 40 * scale)
            Text(title)
                .chromeFont(size: 12)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
        }
        .frame(width: TileMetrics.width * scale, height: TileMetrics.height * scale)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(focused ? 0.14 : hovering ? 0.09 : 0.04))
        )
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
    }

    /// The site's icon at 16 pt (its stored 32 px, crisp on 2x screens) or the host's first letter, on a plate.
    @ViewBuilder
    private var icon: some View {
        if let image = AppModel.shared.favicons.image(for: url) {
            RoundedRectangle(cornerRadius: 10)
                .fill(plate(AppModel.shared.favicons.luminance(for: url)))
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16 * scale, height: 16 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.10))
                .overlay {
                    Text(String(host.first.map { Character($0.uppercased()) } ?? "?"))
                        .chromeFont(size: 18, weight: .bold)
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// The usual faint plate, except that an icon too close to the plate's own brightness to see gets a plate of
    /// the opposite brightness. In dark mode the faint plate measures 0.041 relative luminance, so an icon under
    /// 0.13 (a black logo) is below 2:1 against it; in light mode a mostly white icon (over 0.6) is.
    private func plate(_ luminance: Double?) -> Color {
        switch (colorScheme, luminance) {
        case (.dark, let value?) where value < 0.13: Color.white.opacity(0.85)
        case (.light, let value?) where value > 0.6: Color.black.opacity(0.7)
        default: Color.primary.opacity(0.10)
        }
    }
}

/// Whether the click being handled had Command down (read from the click itself, not the keyboard's state now).
@MainActor
private var commandClicked: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

/// Opens `url` in this tab, or in a background tab after it for Cmd-click and middle-click.
@MainActor
private func open(_ url: URL, in model: BrowserModel, background: Bool) {
    if background {
        model.newTab(url: url, select: false, after: model.selectedTab)
    } else {
        model.go(to: url, typed: false)
    }
}

private struct PinnedTile: View {
    let site: NewTabSite
    let model: BrowserModel
    let app: AppModel
    @FocusState private var focused: Bool
    @State private var editing = false

    private var url: URL? { URL(string: site.url) }
    private var host: String { NewTabSites.siteHost(site.url) ?? site.url }
    private var title: String { site.title.isEmpty ? host : site.title }

    var body: some View {
        TileFace(title: title, url: url, host: host, focused: focused)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { openHere(); return .handled }
            .onKeyPress(.space) { openHere(); return .handled }
            .onDeleteCommand { app.newTab.remove(site.id) }
            .onTapGesture {
                openHere(background: commandClicked)
            }
            .overlay { MiddleClickCatcher { openHere(background: true) } }
            .draggable(site.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                app.newTab.move(id, before: site.id)
                return true
            }
            .contextMenu {
                Button("Open in New Tab") { openHere(background: true) }
                Button("Edit…") { editing = true }
                Button("Remove") { app.newTab.remove(site.id) }
            }
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                SiteForm(app: app, editing: site) { editing = false }.systemText()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(host)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openHere() }
    }

    private func openHere(background: Bool = false) {
        if let url { open(url, in: model, background: background) }
    }
}

private struct FrequentTile: View {
    let entry: HistoryEntry
    let model: BrowserModel
    let app: AppModel
    @FocusState private var focused: Bool

    private var url: URL? { URL(string: entry.url) }
    private var host: String { NewTabSites.siteHost(entry.url) ?? entry.url }
    private var title: String { entry.title.isEmpty ? host : entry.title }

    var body: some View {
        TileFace(title: title, url: url, host: host, focused: focused)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { openHere(); return .handled }
            .onKeyPress(.space) { openHere(); return .handled }
            .onTapGesture {
                openHere(background: commandClicked)
            }
            .overlay { MiddleClickCatcher { openHere(background: true) } }
            .contextMenu {
                Button("Open in New Tab") { openHere(background: true) }
                Button("Pin to New Tab Page") { app.newTab.add(title: entry.title, url: entry.url) }
                Button("Don't Show This Site") { app.newTab.hideFrequent(host: host) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(host)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openHere() }
    }

    private func openHere(background: Bool = false) {
        if let url { open(url, in: model, background: background) }
    }
}

/// The final "+" tile; opens the add form.
private struct AddTile: View {
    @Binding var adding: Bool
    let app: AppModel
    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.chromeScale) private var scale

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .chromeFont(size: 18, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 40 * scale, height: 40 * scale)
            Text("Add Site")
                .chromeFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .frame(width: TileMetrics.width * scale, height: TileMetrics.height * scale)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(focused ? 0.14 : hovering ? 0.09 : 0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(focused ? 0.35 : 0.12), style: StrokeStyle(lineWidth: 1, dash: focused ? [] : [4, 3]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { adding = true; return .handled }
        .onKeyPress(.space) { adding = true; return .handled }
        .onTapGesture { adding = true }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            app.newTab.move(id, before: nil)
            return true
        }
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            SiteForm(app: app, editing: nil) { adding = false }.systemText()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add site")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { adding = true }
    }
}

// MARK: - Form

/// Name and Address for adding or editing a pinned site. A bare domain gets https://.
private struct SiteForm: View {
    let app: AppModel
    let editing: NewTabSite?
    let done: () -> Void
    @State private var name: String
    @State private var address: String
    @State private var message: String?
    @FocusState private var field: Field?

    private enum Field { case name, address }

    init(app: AppModel, editing: NewTabSite?, done: @escaping () -> Void) {
        self.app = app
        self.editing = editing
        self.done = done
        _name = State(initialValue: editing?.title ?? "")
        _address = State(initialValue: editing?.url ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil ? "Add Site" : "Edit Site")
                .font(.headline)
            TextField("Name", text: $name)
                .focused($field, equals: .name)
            TextField("Address", text: $address)
                .focused($field, equals: .address)
                .onSubmit(commit)
            if let message {
                Text(message)
                    .chromeFont(size: 11)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(message)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 280)
        .onAppear { field = editing == nil ? .address : .name }
    }

    private func commit() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard !trimmed.isEmpty, NewTabSites.normalized(full) != nil else {
            message = "Enter a web address, like example.com."
            return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = if let editing {
            app.newTab.update(editing.id, title: title, url: full)
        } else {
            app.newTab.add(title: title, url: full)
        }
        if accepted {
            done()
        } else {
            message = "That address is already pinned or can't be saved."
        }
    }
}
