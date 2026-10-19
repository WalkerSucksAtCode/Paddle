import AppKit
import PaddleCore
import SwiftUI

/// The system's SF Symbols catalog for the icon picker, read once off the main thread the first time a picker opens.
@MainActor @Observable
final class SymbolLibrary {
    static let shared = SymbolLibrary()

    private(set) var catalog: SymbolCatalog?
    @ObservationIgnored private var loading = false

    func load() {
        guard catalog == nil, !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let catalog = SymbolCatalog.load() ?? .fallback
            await MainActor.run { SymbolLibrary.shared.catalog = catalog }
        }
    }

    /// The SF Symbols app's names for the catalog's category keys; an unknown key is shown as itself.
    static func title(of category: String) -> String {
        [
            "draw": "Draw", "variable": "Variable", "multicolor": "Multicolor", "communication": "Communication",
            "weather": "Weather", "maps": "Maps", "objectsandtools": "Objects & Tools", "devices": "Devices",
            "cameraandphotos": "Camera & Photos", "gaming": "Gaming", "connectivity": "Connectivity",
            "transportation": "Transportation", "automotive": "Automotive", "accessibility": "Accessibility",
            "privacyandsecurity": "Privacy & Security", "human": "Human", "home": "Home", "fitness": "Fitness",
            "nature": "Nature", "editing": "Editing", "textformatting": "Text Formatting", "media": "Media",
            "keyboard": "Keyboard", "commerce": "Commerce", "time": "Time", "health": "Health", "shapes": "Shapes",
            "arrows": "Arrows", "indices": "Indices", "math": "Math",
        ][category] ?? category.capitalized
    }
}

extension ColorPreset {
    var swiftUIColor: Color { Color(rgb: color) }
}

/// A Mosaic's icon: its symbol in its tint, else the grid symbol in the secondary color. A saved name this Mac has
/// no symbol for shows the grid too.
struct MosaicIconView: View {
    let layout: PaneLayout
    let size: CGFloat

    var body: some View {
        let chosen = layout.icon.flatMap { NSImage(systemSymbolName: $0.name, accessibilityDescription: nil) == nil ? nil : $0.name }
        Image(systemName: chosen ?? (layout.count == 2 ? "rectangle.split.2x1" : "rectangle.split.2x2"))
            .chromeFont(size: size)
            .foregroundStyle(chosen != nil ? (layout.iconTint?.swiftUIColor ?? Color.primary) : Color.secondary)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Choose Icon, from a Mosaic's menu: the picker over its strip or sidebar item.
    func mosaicIconPopover(split: BrowserModel.Split, model: BrowserModel) -> some View {
        popover(isPresented: Binding(
            get: { model.iconPickerViewID == split.id },
            set: { if !$0, model.iconPickerViewID == split.id { model.iconPickerViewID = nil } }
        ), arrowEdge: .bottom) {
            MosaicIconPicker(model: model, splitID: split.id)
        }
    }
}

/// Choose Icon: every SF Symbol on this Mac, searchable by name and keyword ("cart", "music", "work") and by category,
/// with a tint for it. Picking one sets it at once; Remove Icon goes back to the grid symbol.
struct MosaicIconPicker: View {
    let model: BrowserModel
    let splitID: UUID
    @State private var query = ""
    @State private var category: String?
    @FocusState private var searching: Bool
    private var library = SymbolLibrary.shared

    init(model: BrowserModel, splitID: UUID) {
        self.model = model
        self.splitID = splitID
    }

    private var split: BrowserModel.Split? { model.view(id: splitID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search symbols", text: $query, prompt: Text("Search symbols"))
                    .textFieldStyle(.plain)
                    .focused($searching)
                Picker("Category", selection: $category) {
                    Text("All").tag(String?.none)
                    if let catalog = library.catalog, !catalog.categories.isEmpty {
                        Divider()
                        ForEach(catalog.categories, id: \.self) { key in
                            Text(SymbolLibrary.title(of: key)).tag(String?.some(key))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))

            grid
                .frame(height: 300)

            tints

            HStack {
                if let split {
                    MosaicIconView(layout: split.layout, size: 15)
                        .frame(width: 22)
                    Text(split.layout.icon?.name ?? "Grid symbol (no icon)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Remove Icon") { set(icon: nil) }
                    .disabled(split?.layout.icon == nil)
                Button("Done") { model.iconPickerViewID = nil; dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 400)
        .onAppear {
            library.load()
            DispatchQueue.main.async { searching = true }
        }
    }

    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    private var grid: some View {
        if let catalog = library.catalog {
            let names = catalog.search(query, category: category)
            if names.isEmpty {
                Text("No symbols match “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 40), spacing: 4)], spacing: 4) {
                        ForEach(names, id: \.self) { name in
                            SymbolCell(name: name, selected: split?.layout.icon?.name == name, tint: split?.layout.iconTint) {
                                set(icon: MosaicIcon(name))
                            }
                        }
                    }
                    .padding(2)
                }
                .id(category ?? "all")
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// No tint (the text color) and the presets. Told apart by name too (help and VoiceOver), not by color alone; the
    /// chosen one has a ring and a check.
    private var tints: some View {
        HStack(spacing: 6) {
            Text("Tint").font(.caption).foregroundStyle(.secondary)
            tintButton(nil)
            ForEach(ColorPreset.allCases, id: \.self) { tintButton($0) }
        }
    }

    private func tintButton(_ preset: ColorPreset?) -> some View {
        let selected = split?.layout.iconTint == preset
        return Button {
            if let split { model.setIcon(split.layout.icon, tint: preset, of: split) }
        } label: {
            ZStack {
                Circle()
                    .fill(preset?.swiftUIColor ?? Color.primary.opacity(0.12))
                    .frame(width: 18, height: 18)
                if preset == nil {
                    Image(systemName: "circle.slash").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
                Circle()
                    .strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset?.displayName ?? "No tint")
        .accessibilityLabel(preset.map { "\($0.displayName) tint" } ?? "No tint")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func set(icon: MosaicIcon?) {
        guard let split else { return }
        model.setIcon(icon, tint: icon == nil ? nil : split.layout.iconTint, of: split)
    }
}

private struct SymbolCell: View {
    let name: String
    let selected: Bool
    let tint: ColorPreset?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(selected ? (tint?.swiftUIColor ?? Color.accentColor) : Color.primary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(selected ? 0.16 : hovering ? 0.08 : 0))
                )
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
        .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
