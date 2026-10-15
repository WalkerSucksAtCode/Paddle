import Foundation

/// The tabs another browser had open when it last ran.
public struct SessionReadResult: Sendable {
    public var windows: [WindowRecord]
    /// Tabs kept across all windows.
    public var tabs: Int
    /// Tabs left out because their page isn't http or https (settings pages, new tabs, files).
    public var skippedNotWeb: Int
    /// More than `BrowserSessionReader.tabCap` tabs were open; the rest were left out.
    public var truncated: Bool
}

public enum BrowserSessionReader {
    /// Most tabs imported in one go.
    public static let tabCap = 500

    /// Reads the last session of a Chromium-family browser (SNSS files) or Firefox (`sessionstore` files). Never
    /// touches the Keychain: a session file Chrome has encrypted is refused instead.
    public static func read(_ source: ImportSource) throws -> SessionReadResult {
        switch source.browser.family {
        case .safari:
            throw BrowserImportError.unreadable("Paddle can't read Safari's open tabs yet.")
        case .chromium:
            return finish(try readChromium(source))
        case .firefox:
            return finish(try readFirefox(source))
        }
    }

    // MARK: - Shared filtering

    private struct RawTab {
        var url: String
        var title: String
        var pinned: Bool
        var hidden = false
    }

    private struct RawWindow {
        var tabs: [RawTab]
        var selected: Int
    }

    private static func isWeb(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Keeps web tabs up to the cap, puts pinned tabs first and recomputes each window's selected tab.
    private static func finish(_ raws: [RawWindow]) -> SessionReadResult {
        var result = SessionReadResult(windows: [], tabs: 0, skippedNotWeb: 0, truncated: false)
        for raw in raws {
            var kept = [Bool](repeating: false, count: raw.tabs.count)
            // Pinned tabs count against the cap first, so a late pinned tab isn't cut for earlier unpinned ones.
            let order = raw.tabs.indices.filter { raw.tabs[$0].pinned } + raw.tabs.indices.filter { !raw.tabs[$0].pinned }
            for i in order where !raw.tabs[i].hidden {
                let tab = raw.tabs[i]
                guard isWeb(tab.url) else { result.skippedNotWeb += 1; continue }
                guard result.tabs < tabCap else { result.truncated = true; continue }
                result.tabs += 1
                kept[i] = true
            }
            let indices = raw.tabs.indices.filter { kept[$0] }
            guard let first = indices.first else { continue }
            // The selected tab if kept, else the nearest kept tab before it, else the first.
            var selected = first
            if !raw.tabs.isEmpty {
                let start = min(max(raw.selected, 0), raw.tabs.count - 1)
                if let found = stride(from: start, through: 0, by: -1).first(where: { kept[$0] }) { selected = found }
            }
            let ordered = indices.filter { raw.tabs[$0].pinned } + indices.filter { !raw.tabs[$0].pinned }
            let records = ordered.map {
                TabRecord(url: raw.tabs[$0].url, title: raw.tabs[$0].title, isPinned: raw.tabs[$0].pinned)
            }
            result.windows.append(WindowRecord(tabs: records, selectedIndex: ordered.firstIndex(of: selected) ?? 0))
        }
        return result
    }

    private static func load(_ url: URL, _ browser: ImportSource.Browser) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            if ImportSQLite.isPermissionDenied(error) { throw BrowserImportError.accessDenied(browser) }
            throw BrowserImportError.unreadable("Paddle couldn't read \(browser.displayName)'s last session.")
        }
    }

    // MARK: - Chromium

    /// `Sessions/Session_<n>` with the largest n (not the newest file), else the old `Current Session`, `Last Session`.
    static func chromiumSessionFile(in directory: URL, _ fm: FileManager = .default) -> URL? {
        let sessions = directory.appending(path: "Sessions", directoryHint: .isDirectory)
        let numbered = ((try? fm.contentsOfDirectory(atPath: sessions.path)) ?? []).compactMap { name -> (Int, String)? in
            guard name.hasPrefix("Session_"), let n = Int(name.dropFirst("Session_".count)), n >= 0 else { return nil }
            return (n, name)
        }
        if let best = numbered.max(by: { $0.0 < $1.0 }) { return sessions.appending(path: best.1) }
        for name in ["Current Session", "Last Session"] {
            let url = directory.appending(path: name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func readChromium(_ source: ImportSource) throws -> [RawWindow] {
        guard let file = chromiumSessionFile(in: source.directory) else {
            throw BrowserImportError.missing("The last session")
        }
        let data = try load(file, source.browser)
        return try SNSS.decode(data).map { window in
            RawWindow(
                tabs: window.tabs.map { RawTab(url: $0.url, title: $0.title, pinned: $0.pinned) },
                selected: window.selected)
        }
    }

    // MARK: - Firefox

    private static func readFirefox(_ source: ImportSource) throws -> [RawWindow] {
        let fm = FileManager.default
        let candidates = ["sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4", "sessionstore-backups/previous.jsonlz4"]
            .map { source.directory.appending(path: $0) }
        guard let file = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw BrowserImportError.missing("The last session")
        }
        let data = try load(file, source.browser)
        if let windows = try? decodeFirefox(data) { return windows }
        let backup = source.directory.appending(path: "sessionstore-backups/recovery.baklz4")
        if fm.fileExists(atPath: backup.path) {
            let backupData = try load(backup, source.browser)
            if let windows = try? decodeFirefox(backupData) { return windows }
        }
        throw BrowserImportError.unreadable("Paddle couldn't read Firefox's last session.")
    }

    private static func decodeFirefox(_ file: Data) throws -> [RawWindow] {
        let json = try MozLZ4.decompress(file, maxOutput: 256 * 1024 * 1024)
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]] else {
            throw BrowserImportError.unreadable("Paddle couldn't read Firefox's last session.")
        }
        return windows.map { window in
            let tabs = (window["tabs"] as? [[String: Any]] ?? []).map { tab -> RawTab in
                // A tab without history keeps its slot (hidden) so `selected` still points at the right tab.
                guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else {
                    return RawTab(url: "", title: "", pinned: false, hidden: true)
                }
                let wanted = (tab["index"] as? Int) ?? entries.count
                let entry = entries[min(max(wanted, 1), entries.count) - 1]
                return RawTab(
                    url: entry["url"] as? String ?? "", title: entry["title"] as? String ?? "",
                    pinned: tab["pinned"] as? Bool ?? false, hidden: tab["hidden"] as? Bool ?? false)
            }
            return RawWindow(tabs: tabs, selected: ((window["selected"] as? Int) ?? 1) - 1)
        }
    }
}
