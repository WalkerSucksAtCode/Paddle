import Foundation
import Observation
import PaddleCore

/// The chrome themes: the built-ins, then the `*.json` files in `themes/`. Read at launch and on Reload Config.
@Observable
final class ThemeStore {
    /// Built-ins first, then files sorted by name.
    private(set) var available: [ChromeTheme] = BuiltInThemes.all
    /// Problems reading the files, each prefixed "themes/<file>.json: ".
    private(set) var warnings: [String] = []
    /// Files that didn't parse or were skipped; a `theme` naming one falls back to Default with the file's warning.
    private(set) var unreadableIDs: Set<String> = []

    func theme(id: String) -> ChromeTheme? {
        available.first { $0.id == id }
    }

    func load() {
        var themes = BuiltInThemes.all
        var warnings: [String] = []
        var unreadable: Set<String> = []
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.themes, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension.lowercased() == "json" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let id = file.deletingPathExtension().lastPathComponent
            let prefix = "themes/\(file.lastPathComponent): "
            if id.lowercased() == "default" || BuiltInThemes.all.contains(where: { $0.id == id }) {
                warnings.append(prefix + "has the name of a built-in theme, so it is skipped")
                unreadable.insert(id)
                continue
            }
            do {
                let decoded = try ChromeTheme.decode(id: id, data: Data(contentsOf: file))
                themes.append(decoded.theme)
                warnings += decoded.warnings.map { prefix + $0 }
            } catch {
                warnings.append(prefix + "isn't a JSON object (\(error.localizedDescription)); using Default")
                unreadable.insert(id)
            }
        }
        available = themes
        self.warnings = warnings
        unreadableIDs = unreadable
    }
}
