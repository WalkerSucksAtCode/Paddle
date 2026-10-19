import PaddleCore
import SwiftUI

/// Shows the Edit Space popover when `model.editSpaceRequest` changes (Tabs > Edit Space…, New Space, the switcher's
/// menu, the sidebar's context menu). Put it on a view that is always in the chrome, so a request made as the
/// switcher first appears is not missed.
private struct SpaceEditPopover: ViewModifier {
    let model: BrowserModel
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.editSpaceRequest) { _, _ in shown = true }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                SpaceEditor(model: model, space: model.activeSpace)
                    .systemText()
                    .padding(12)
                    .frame(width: 400)
            }
    }
}

extension View {
    func spaceEditPopover(model: BrowserModel) -> some View { modifier(SpaceEditPopover(model: model)) }
}

/// Name, symbol and tint of one space.
private struct SpaceEditor: View {
    let model: BrowserModel
    @Bindable var space: Space
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $draft, selection: $selection)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, now in if !now { commit() } }
            HStack(spacing: 6) {
                Image(systemName: space.symbol.shown).frame(width: 18)
                Text("Symbol").font(.caption).foregroundStyle(.secondary)
            }
            // The name field keeps the keyboard; the grid's search is a click away.
            SymbolGrid(selected: space.symbol.sfSymbol, height: 200, focusesSearch: false) { name in
                if let symbol = SpaceSymbol(name) { model.setSymbol(symbol, of: space.id) }
            }
            Picker("Tint", selection: Binding(get: { space.tint }, set: { model.setTint($0, of: space.id) })) {
                Text("None").tag(ColorPreset?.none)
                ForEach(ColorPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(ColorPreset?.some(preset))
                }
            }
        }
        .onAppear {
            draft = space.name
            // Next turn, so the popover is up before the field takes the focus.
            DispatchQueue.main.async {
                focused = true
                selection = TextSelection(range: draft.startIndex..<draft.endIndex)
            }
        }
        .onDisappear { commit() }
    }

    /// An empty name keeps the old one.
    private func commit() {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = space.name
        } else if draft != space.name {
            model.renameSpace(space.id, to: draft)
        }
    }
}

private extension BrowserModel {
    /// Makes the space active, then opens its Edit Space popover.
    func editSpace(_ id: String) {
        switchToSpace(id)
        editSpaceRequest += 1
    }

    /// Makes the space active, then asks to delete it (Tabs > Delete Space).
    func requestDelete(_ id: String) {
        let before = activeSpaceID
        switchToSpace(id)
        controller?.deleteActiveSpace { [weak self] deleted in
            if !deleted { self?.switchToSpace(before) }
        }
    }

    func addSpace() {
        newSpace()
        editSpaceRequest += 1
    }
}

// MARK: - Horizontal switcher

/// The button at the start of the tab strip: the active space's symbol and name, and a menu of spaces.
struct SpaceSwitcher: View {
    /// Width at text size 100 %; longer names truncate.
    static let width: CGFloat = 130
    let model: BrowserModel
    @State private var hovering = false
    @Environment(\.chromeScale) private var scale
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let space = model.activeSpace
        let ink: Color = theme?.text ?? .primary
        Menu {
            // The Tabs menu owns the Control-number shortcuts; a second registration here could clash.
            ForEach(model.spaces) { item in
                Toggle(isOn: Binding(get: { item.id == model.activeSpaceID }, set: { _ in model.switchToSpace(item.id) })) {
                    Label(item.name, systemImage: item.symbol.shown)
                }
            }
            Divider()
            Button("New Space") { model.addSpace() }
            Button("Edit Space…") { model.editSpaceRequest += 1 }
            Button("Delete Space") { model.requestDelete(model.activeSpaceID) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: space.symbol.shown)
                Text(space.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .chromeFont(size: 12, weight: .medium)
            .padding(.horizontal, 8)
            .frame(width: Self.width * scale, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(ink.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .help("Space: \(space.name)")
        .accessibilityLabel("Space \(space.name)")
    }
}

// MARK: - Sidebar

/// The active space's symbol and name above the pinned grid.
struct SpaceHeaderRow: View {
    let space: Space
    @Environment(\.chromeScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol.shown)
            Text(space.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .chromeFont(size: 12, weight: .medium)
        .padding(.horizontal, 10)
        .frame(height: 26 * scale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Space \(space.name)")
    }
}

/// The row of space buttons at the bottom of the sidebar, stacked vertically when the sidebar is collapsed.
struct SpaceButtonsRow: View {
    let model: BrowserModel
    let vertical: Bool

    var body: some View {
        Group {
            if vertical {
                ScrollView(.vertical, showsIndicators: false) { VStack(spacing: 4) { buttons } }
                    .frame(maxHeight: 240)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 4)], alignment: .leading, spacing: 4) { buttons }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(model.spaces) { space in
            SpaceButton(model: model, space: space, active: space.id == model.activeSpaceID)
        }
        Button {
            model.addSpace()
        } label: {
            Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New Space")
        .accessibilityLabel("New Space")
    }
}

/// One space as a symbol button. The active one has a stronger fill and an edge: told apart by brightness, and the
/// name is its help and VoiceOver label.
private struct SpaceButton: View {
    let model: BrowserModel
    let space: Space
    let active: Bool
    @State private var hovering = false
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let ink: Color = theme?.text ?? .primary
        Button {
            model.switchToSpace(space.id)
        } label: {
            Image(systemName: space.symbol.shown)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(ink.opacity(active ? 0.22 : hovering ? 0.10 : 0))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(ink.opacity(active ? 0.45 : 0), lineWidth: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .contextMenu {
            Button("Edit Space…") { model.editSpace(space.id) }
            Button("Delete Space") { model.requestDelete(space.id) }
                .disabled(model.spaces.count < 2)
        }
    }
}
