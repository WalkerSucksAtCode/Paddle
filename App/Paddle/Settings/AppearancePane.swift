import PaddleCore
import SwiftUI

/// Settings > Appearance: light or dark, tab layout, the size of Paddle's own text, page zoom and minimum font size,
/// and the accessibility options.
struct AppearancePane: View {
    let model: SettingsModel

    /// Default zoom choices (percent); a value set by hand is added to them.
    private static let zoomLevels = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200]
    /// Minimum font sizes (points); 0 is off.
    private static let fontSizes = [0, 9, 10, 11, 12, 14, 16, 18, 20, 24]

    var body: some View {
        SettingsForm {
            Section("Windows") {
                Picker("Appearance", selection: Binding(
                    get: { model.file.appearance },
                    set: { value in Task { await model.saveKey(.appearance, .string(value.rawValue)) } }
                )) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .help("appearance in config.json. System follows macOS; pages follow the window.")
                Picker("Tab layout", selection: Binding(
                    get: { model.file.tabLayout },
                    set: { value in Task { await model.saveKey(.tabLayout, .string(value.rawValue)) } }
                )) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }
                .help("tabLayout in config.json, View > Vertical Tabs. Vertical shows the tabs in a sidebar.")
                Picker("Text size", selection: Binding(
                    get: { model.file.interfaceTextSize },
                    set: { value in Task { await model.saveKey(.interfaceTextSize, .string(value.rawValue)) } }
                )) {
                    Text("Small").tag(InterfaceTextSize.small)
                    Text("Default").tag(InterfaceTextSize.default)
                    Text("Large").tag(InterfaceTextSize.large)
                    Text("Larger").tag(InterfaceTextSize.larger)
                }
                .help("interfaceTextSize in config.json. The size of Paddle's own text: tabs, toolbar and bars. Pages are not affected.")
                Toggle("High-contrast selected tab", isOn: Binding(
                    get: { model.file.highContrastTabs },
                    set: { value in Task { await model.saveKey(.highContrastTabs, .bool(value)) } }
                ))
                .help("highContrastTabs in config.json. Draws the selected tab with a stronger outline and brightness difference.")
            }
            .disabled(model.controlsDisabled)
            Section("Pages") {
                zoomPicker
                fontSizePicker
            }
            .disabled(model.controlsDisabled)
            Section("Accessibility") {
                Toggle("Always reduce motion", isOn: Binding(
                    get: { model.file.reduceMotion == .always },
                    set: { value in Task { await model.saveKey(.reduceMotion, .string(value ? "always" : "system")) } }
                ))
                .help("reduceMotion in config.json. Off follows System Settings > Accessibility > Display.")
                Toggle("Always reduce transparency", isOn: Binding(
                    get: { model.file.reduceTransparency == .always },
                    set: { value in Task { await model.saveKey(.reduceTransparency, .string(value ? "always" : "system")) } }
                ))
                .help("reduceTransparency in config.json. Off follows System Settings > Accessibility > Display.")
            }
            .disabled(model.controlsDisabled)
        }
    }

    private var zoomPicker: some View {
        let current = Int((model.file.defaultZoom * 100).rounded())
        let levels = Self.zoomLevels.contains(current) ? Self.zoomLevels : (Self.zoomLevels + [current]).sorted()
        return Picker("Default zoom", selection: Binding(
            get: { current },
            set: { percent in Task { await model.saveKey(.defaultZoom, .number(SitePolicy.normalizedZoom(Double(percent) / 100))) } }
        )) {
            ForEach(levels, id: \.self) { Text("\($0) %").tag($0) }
        }
        .help("defaultZoom in config.json. The zoom of sites with none of their own (Settings > Sites); View > Actual Size returns a page to it.")
    }

    private var fontSizePicker: some View {
        let current = Int(model.file.minimumFontSize.rounded())
        let sizes = Self.fontSizes.contains(current) ? Self.fontSizes : (Self.fontSizes + [current]).sorted()
        return Picker("Minimum font size", selection: Binding(
            get: { current },
            set: { size in Task { await model.saveKey(.minimumFontSize, .number(Double(size))) } }
        )) {
            ForEach(sizes, id: \.self) { Text($0 == 0 ? "Off" : "\($0) pt").tag($0) }
        }
        .help("minimumFontSize in config.json. Pages never show text smaller than this; Off leaves the page's sizes alone.")
    }
}
