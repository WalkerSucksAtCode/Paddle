import PaddleCore
import SwiftUI

/// A Mosaic in the tab strip: one item in place of its tabs, with a grid symbol, its name and how many panes it
/// has. A click shows the Mosaic; the chevron (or a right-click) opens its menu.
struct ViewStripButton: View {
    let split: BrowserModel.Split
    let model: BrowserModel
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.chromeTheme) private var theme
    @Environment(\.chromeHighContrastTabs) private var highContrast

    private var isShown: Bool { model.selectedTab.map(split.contains) ?? false }

    var body: some View {
        let ink: Color = theme?.text ?? .primary
        HStack(spacing: 6) {
            Image(systemName: split.layout.count == 2 ? "rectangle.split.2x1" : "rectangle.split.2x2")
                .chromeFont(size: 11)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.displayName(of: split))
                .chromeFont(size: 12, weight: highContrast && isShown ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(split.layout.count)")
                .chromeFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .background(Capsule().fill(ink.opacity(0.10)))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Menu {
                ViewMenu(split: split, model: model)
            } label: {
                Image(systemName: "chevron.down").chromeFont(size: 9, weight: .semibold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("This Mosaic's tabs and options")
            .accessibilityLabel("Mosaic menu")
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isShown ? (theme?.selectedTab ?? ink.opacity(highContrast ? 0.30 : 0.14)) : ink.opacity(hovering ? 0.06 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(ink.opacity(isShown ? (highContrast ? 0.55 : 0.18) : 0), lineWidth: highContrast ? 1.5 : 1)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectView(split) }
        .onHover { hovering = $0 }
        .contextMenu { ViewMenu(split: split, model: model) }
        .viewRenamePopover(split: split, model: model)
        // A tab dragged here joins the Mosaic.
        .background(ViewDropAnchor(model: model, viewID: split.id))
        .overlay {
            if model.viewDropTargetID == split.id {
                RoundedRectangle(cornerRadius: 7).strokeBorder(theme?.accent ?? Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .help("\(model.displayName(of: split)): " + model.panes(of: split).map(\.displayTitle).joined(separator: ", "))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mosaic \(model.displayName(of: split)), \(split.layout.count) tabs")
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectView(split) }
        .id(split.id)
    }
}

/// A Mosaic in the vertical sidebar: one row in place of its tabs, like `ViewStripButton`.
struct ViewSidebarRow: View {
    let split: BrowserModel.Split
    let model: BrowserModel
    let iconsOnly: Bool
    @State private var hovering = false
    @Environment(\.chromeTheme) private var theme
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeHighContrastTabs) private var highContrast

    private var isShown: Bool { model.selectedTab.map(split.contains) ?? false }

    var body: some View {
        let ink: Color = theme?.text ?? .primary
        HStack(spacing: 8) {
            Image(systemName: split.layout.count == 2 ? "rectangle.split.2x1" : "rectangle.split.2x2")
                .chromeFont(size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            if !iconsOnly {
                Text(model.displayName(of: split))
                    .chromeFont(size: 12.5, weight: highContrast && isShown ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(split.layout.count)")
                    .chromeFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(ink.opacity(0.10)))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Menu {
                    ViewMenu(split: split, model: model)
                } label: {
                    Image(systemName: "chevron.down").chromeFont(size: 9, weight: .semibold)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("This Mosaic's tabs and options")
                .accessibilityLabel("Mosaic menu")
            }
        }
        .padding(.horizontal, iconsOnly ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: iconsOnly ? .center : .leading)
        .frame(height: 30 * scale)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isShown ? (theme?.selectedTab ?? ink.opacity(highContrast ? 0.36 : 0.14)) : ink.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectView(split) }
        .onHover { hovering = $0 }
        .contextMenu { ViewMenu(split: split, model: model) }
        .viewRenamePopover(split: split, model: model)
        // A tab dragged here joins the Mosaic.
        .background(ViewDropAnchor(model: model, viewID: split.id))
        .overlay {
            if model.viewDropTargetID == split.id {
                RoundedRectangle(cornerRadius: 7).strokeBorder(theme?.accent ?? Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .help("\(model.displayName(of: split)): " + model.panes(of: split).map(\.displayTitle).joined(separator: ", "))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mosaic \(model.displayName(of: split)), \(split.layout.count) tabs")
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectView(split) }
    }
}

/// A Mosaic's menu: its tabs (choose one to show it focused), then Rename Mosaic…, its layouts, Even Out Panes, Move
/// Tab Out and End Mosaic.
struct ViewMenu: View {
    let split: BrowserModel.Split
    let model: BrowserModel

    var body: some View {
        let tabs = model.panes(of: split)
        Section("Tabs in This Mosaic") {
            ForEach(tabs, id: \.id) { tab in
                Button(tab.displayTitle) { model.select(tab) }
            }
        }
        Divider()
        Button("Rename Mosaic…") { model.renamingViewID = split.id }
        Menu("Layout") {
            ForEach(PaneArrangement.allCases, id: \.self) { arrangement in
                Button {
                    model.selectView(split)
                    model.arrangeMosaic(arrangement)
                } label: {
                    Label(arrangement.title, systemImage: arrangement.symbol)
                }
            }
        }
        Button("Even Out Panes") {
            model.selectView(split)
            model.equalizePanes()
        }
        Menu("Move Tab Out of Mosaic") {
            ForEach(tabs, id: \.id) { tab in
                Button(tab.displayTitle) { model.removeFromView(tab) }
            }
        }
        Divider()
        Button("End Mosaic") { if let first = tabs.first { model.endSplit(of: first) } }
    }
}

extension View {
    /// Rename Mosaic: a popover with the name field; an empty name goes back to the focused pane's site.
    func viewRenamePopover(split: BrowserModel.Split, model: BrowserModel) -> some View {
        popover(isPresented: Binding(
            get: { model.renamingViewID == split.id },
            set: { if !$0, model.renamingViewID == split.id { model.renamingViewID = nil } }
        ), arrowEdge: .bottom) {
            ViewNameField(split: split, model: model)
        }
    }
}

struct ViewNameField: View {
    let split: BrowserModel.Split
    let model: BrowserModel
    /// Called after the name is set, for a popover other than the strip item's (the Mosaic bar's).
    var done: () -> Void = {}
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("Mosaic name", text: $name, prompt: Text(model.displayName(of: BrowserModel.Split(layout: split.layout.unnamed))))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($focused)
                .onSubmit(commit)
            Button("Done", action: commit).keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .onAppear {
            name = split.layout.name ?? ""
            focused = true
        }
    }

    private func commit() {
        if let current = model.view(id: split.id) { model.renameView(current, to: name) }
        model.renamingViewID = nil
        done()
    }
}
