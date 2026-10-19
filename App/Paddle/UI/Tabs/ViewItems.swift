import PaddleCore
import SwiftUI

/// A Mosaic in the tab strip: one item in place of its tabs, with its icon (a grid symbol until one is chosen), its name and how many panes it
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
            MosaicStripBadge(model: model, split: split, size: 11)
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
        .modifier(MosaicStripShade(model: model, split: split, cornerRadius: 7))
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
        .mosaicIconPopover(split: split, model: model)
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
            MosaicStripBadge(model: model, split: split, size: 12)
                .frame(minWidth: 16)
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
        .modifier(MosaicStripShade(model: model, split: split, cornerRadius: 7))
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isShown ? (theme?.selectedTab ?? ink.opacity(highContrast ? 0.36 : 0.14)) : ink.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectView(split) }
        .onHover { hovering = $0 }
        .contextMenu { ViewMenu(split: split, model: model) }
        .viewRenamePopover(split: split, model: model)
        .mosaicIconPopover(split: split, model: model)
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
/// Tab Out and End Mosaic. Choose Icon… opens the icon picker.
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
        Button("Choose Icon…") { model.iconPickerViewID = split.id }
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

/// A Mosaic's strip and sidebar icon (`mosaicStripIcon`): its own icon, or its panes' site icons in a row.
struct MosaicStripBadge: View {
    let model: BrowserModel
    let split: BrowserModel.Split
    let size: CGFloat

    var body: some View {
        if model.config.mosaicStripIcon == .favicons {
            HStack(spacing: 2) {
                ForEach(model.panes(of: split).prefix(PaneLayout.maxPanes), id: \.id) { tab in
                    FaviconView(url: tab.url, size: size)
                }
            }
            .accessibilityHidden(true)
        } else {
            MosaicIconView(layout: split.layout, size: size)
        }
    }
}

/// The shading that sets a Mosaic's strip or sidebar item apart from tabs (`mosaicStripShading`): a fill and/or an
/// outline (`mosaicStripStyle`) in `mosaicStripColor` at `mosaicStripStrength`. The outline is drawn stronger than the
/// fill, so the item stands out by brightness and edge, not by its color alone.
struct MosaicStripShade: ViewModifier {
    let model: BrowserModel
    let split: BrowserModel.Split
    let cornerRadius: CGFloat
    @Environment(\.chromeTheme) private var theme

    func body(content: Content) -> some View {
        let config = model.config
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let color = Self.color(config.mosaicStripColor, layout: split.layout, accent: theme?.accent ?? Color.accentColor)
        let strength = config.mosaicStripStrength / 100
        content
            .overlay {
                if config.mosaicStripShading, config.mosaicStripStyle != .fill {
                    shape.strokeBorder(color.opacity(min(1, strength * 3 + 0.15)), lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .background {
                if config.mosaicStripShading, config.mosaicStripStyle != .outline {
                    shape.fill(color.opacity(strength))
                }
            }
    }

    /// "accent", "icon" (the Mosaic's icon tint, else the accent), a color name or #rrggbb.
    static func color(_ value: String, layout: PaneLayout, accent: Color) -> Color {
        if value == "icon" { return layout.iconTint?.swiftUIColor ?? accent }
        switch ColorChoice(configValue: value, automaticValue: "accent") {
        case .preset(let preset)?: return preset.swiftUIColor
        case .custom(let rgb)?: return Color(rgb: rgb)
        default: return accent
        }
    }
}
