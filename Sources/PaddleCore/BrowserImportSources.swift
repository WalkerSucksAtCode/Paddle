import Foundation

/// A browser profile Paddle can import from, found by `BrowserImport.discoverSources`.
public struct ImportSource: Sendable, Equatable, Identifiable {
    public enum Browser: String, Sendable, CaseIterable {
        case safari, chrome, brave, edge, arc, chromium, firefox

        public var displayName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Google Chrome"
            case .brave: "Brave"
            case .edge: "Microsoft Edge"
            case .arc: "Arc"
            case .chromium: "Chromium"
            case .firefox: "Firefox"
            }
        }

        /// Which file formats the browser keeps its history and settings in.
        public var family: Family {
            switch self {
            case .safari: .safari
            case .firefox: .firefox
            case .chrome, .brave, .edge, .arc, .chromium: .chromium
            }
        }
    }

    public enum Family: Sendable { case safari, chromium, firefox }

    public var browser: Browser
    /// The profile's name as the browser shows it ("Person 1", "default-release"); empty for Safari, which has one.
    public var profileName: String
    /// The profile's folder.
    public var directory: URL
    /// Chrome `History`, Firefox `places.sqlite`, Safari `History.db`.
    public var historyFile: URL
    /// Chrome `Preferences`, Firefox `prefs.js`, Safari's `com.apple.Safari.plist`.
    public var settingsFile: URL
    /// Firefox `search.json.mozlz4` (the engine list and the default); nil for the others.
    public var searchFile: URL?
    /// The files exist. Safari's can't be checked without Full Disk Access, so it is always offered and a read
    /// that macOS refuses says so (`BrowserImportError.accessDenied`).
    public var hasHistory: Bool
    public var hasSettings: Bool
    /// Chrome `Bookmarks` (JSON), Firefox `places.sqlite`, Safari `Bookmarks.plist`; nil for the Full Disk Access placeholder.
    public var bookmarksFile: URL?
    public var hasBookmarks: Bool
    /// The profile keeps a last session (Chrome `Sessions/`, Firefox `sessionstore*.jsonlz4`).
    public var hasOpenTabs: Bool
    /// Per-site zoom and permissions are on disk (Chrome `Preferences`, Firefox `permissions.sqlite` / `content-prefs.sqlite`).
    public var hasSiteSettings: Bool
    /// The profile lists installed extensions (Chrome `Secure Preferences`, Firefox `extensions.json`).
    public var hasExtensions: Bool
    /// macOS refuses Paddle the browser's folder, so its profiles can't be listed. The source stands for the whole
    /// browser: `profileName` is empty, nothing is offered, and `directory`, `historyFile` and `settingsFile` are the
    /// browser's base folder (nothing is read from it).
    public var needsFullDiskAccess: Bool

    public var id: String { historyFile.path }

    public var title: String { profileName.isEmpty ? browser.displayName : "\(browser.displayName) – \(profileName)" }

    public init(
        browser: Browser, profileName: String, directory: URL, historyFile: URL, settingsFile: URL,
        searchFile: URL? = nil, hasHistory: Bool, hasSettings: Bool, needsFullDiskAccess: Bool = false,
        bookmarksFile: URL? = nil, hasBookmarks: Bool = false, hasOpenTabs: Bool = false,
        hasSiteSettings: Bool = false, hasExtensions: Bool = false
    ) {
        self.browser = browser
        self.profileName = profileName
        self.directory = directory
        self.historyFile = historyFile
        self.settingsFile = settingsFile
        self.searchFile = searchFile
        self.hasHistory = hasHistory
        self.hasSettings = hasSettings
        self.needsFullDiskAccess = needsFullDiskAccess
        self.bookmarksFile = bookmarksFile
        self.hasBookmarks = hasBookmarks
        self.hasOpenTabs = hasOpenTabs
        self.hasSiteSettings = hasSiteSettings
        self.hasExtensions = hasExtensions
    }
}

/// Why reading another browser's files failed, in words for the import sheet.
public enum BrowserImportError: Error, Equatable, Sendable, LocalizedError {
    case accessDenied(ImportSource.Browser)
    case missing(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(.safari):
            "Safari's history is protected by macOS. To import it, allow Paddle in System Settings > Privacy & Security > Full Disk Access, or export bookmarks from Safari as HTML."
        case .accessDenied(let browser):
            "\(browser.displayName)'s data is protected by macOS. To import it, allow Paddle in System Settings > Privacy & Security > Full Disk Access."
        case .missing(let what):
            "\(what) wasn't found."
        case .unreadable(let why):
            why
        }
    }
}

public enum BrowserImport {
    /// Chromium-family browsers whose profiles share Chrome's layout: `<base>/Local State` and
    /// `<base>/<Default | Profile N>/{History, Preferences}`. Bases are relative to the home folder.
    static let chromiumBases: [(ImportSource.Browser, String)] = [
        (.chrome, "Library/Application Support/Google/Chrome"),
        (.brave, "Library/Application Support/BraveSoftware/Brave-Browser"),
        (.edge, "Library/Application Support/Microsoft Edge"),
        (.arc, "Library/Application Support/Arc/User Data"),
        (.chromium, "Library/Application Support/Chromium"),
    ]

    /// The browsers and profiles under `home` that have something to import. Safari is always listed (see
    /// `ImportSource.hasHistory`); the others only when their folders exist and hold history or settings. A browser
    /// whose folder macOS refuses is listed once, as `needsFullDiskAccess`. Reads only profile names (`Local State`,
    /// `profiles.ini`), never history, settings or sign-in data.
    public static func discoverSources(home: URL, fileManager: FileManager = .default) -> [ImportSource] {
        var sources = [safari(home: home)]
        for (browser, base) in chromiumBases {
            sources += chromiumProfiles(browser, base: home.appending(path: base, directoryHint: .isDirectory), fileManager)
        }
        sources += firefoxProfiles(
            base: home.appending(path: "Library/Application Support/Firefox", directoryHint: .isDirectory), fileManager)
        return sources
    }

    // MARK: - Safari

    static func safari(home: URL) -> ImportSource {
        ImportSource(
            browser: .safari, profileName: "",
            directory: home.appending(path: "Library/Safari", directoryHint: .isDirectory),
            historyFile: home.appending(path: "Library/Safari/History.db"),
            settingsFile: home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"),
            hasHistory: true, hasSettings: true,
            // Like the history, none of these can be checked without Full Disk Access.
            bookmarksFile: home.appending(path: "Library/Safari/Bookmarks.plist"), hasBookmarks: true
        )
    }

    /// The one source for a browser whose folder macOS won't let Paddle read (see `ImportSource.needsFullDiskAccess`).
    private static func needsFullDiskAccess(_ browser: ImportSource.Browser, base: URL) -> ImportSource {
        ImportSource(
            browser: browser, profileName: "", directory: base, historyFile: base, settingsFile: base,
            hasHistory: false, hasSettings: false, needsFullDiskAccess: true
        )
    }

    // MARK: - Chromium family

    private static func chromiumProfiles(_ browser: ImportSource.Browser, base: URL, _ fm: FileManager) -> [ImportSource] {
        // `fileExists` says false both for a missing folder and for one macOS refuses, so the listing's error decides.
        let listed: [String]
        do {
            listed = try fm.contentsOfDirectory(atPath: base.path)
        } catch {
            return BrowserHistoryReader.isPermissionDenied(error) || fm.fileExists(atPath: base.path)
                ? [needsFullDiskAccess(browser, base: base)] : []
        }

        // Profile folder to display name, from Local State's `profile.info_cache`; folders it doesn't list are
        // found by name ("Default", "Profile 1", …).
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: base.appending(path: "Local State")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, value) in cache {
                if let name = (value as? [String: Any])?["name"] as? String, !name.isEmpty { names[folder] = name }
            }
        }
        let folders = listed.filter { $0 == "Default" || $0.hasPrefix("Profile ") || names[$0] != nil }
        return folders.compactMap { folder -> ImportSource? in
            // A folder name is a single path component: never follow one that climbs out of the base.
            guard !folder.contains("/"), folder != "..", folder != "." else { return nil }
            let directory = base.appending(path: folder, directoryHint: .isDirectory)
            let history = directory.appending(path: "History")
            let preferences = directory.appending(path: "Preferences")
            let hasHistory = fm.fileExists(atPath: history.path)
            let hasSettings = fm.fileExists(atPath: preferences.path)
            let bookmarks = directory.appending(path: "Bookmarks")
            let hasBookmarks = fm.fileExists(atPath: bookmarks.path)
            var isFolder: ObjCBool = false
            let hasOpenTabs = fm.fileExists(atPath: directory.appending(path: "Sessions").path, isDirectory: &isFolder) && isFolder.boolValue
            let hasExtensions = fm.fileExists(atPath: directory.appending(path: "Secure Preferences").path)
            guard hasHistory || hasSettings || hasBookmarks || hasOpenTabs || hasExtensions else { return nil }
            return ImportSource(
                browser: browser, profileName: names[folder] ?? folder, directory: directory,
                historyFile: history, settingsFile: preferences, hasHistory: hasHistory, hasSettings: hasSettings,
                bookmarksFile: bookmarks, hasBookmarks: hasBookmarks, hasOpenTabs: hasOpenTabs,
                hasSiteSettings: hasSettings, hasExtensions: hasExtensions
            )
        }
        .sorted { lhs, rhs in
            let lhsDefault = lhs.directory.lastPathComponent == "Default"
            let rhsDefault = rhs.directory.lastPathComponent == "Default"
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.profileName.localizedStandardCompare(rhs.profileName) == .orderedAscending
        }
    }

    // MARK: - Firefox

    /// `profiles.ini` is an INI file: `[Profile0]` sections with `Name`, `Path`, `IsRelative` (1: relative to the
    /// Firefox folder) and `Default=1` on the profile new windows use. `[Install…]` sections are not profiles.
    private static func firefoxProfiles(base: URL, _ fm: FileManager) -> [ImportSource] {
        let ini = base.appending(path: "profiles.ini")
        let text: String
        do {
            text = try String(contentsOf: ini, encoding: .utf8)
        } catch {
            // No profiles.ini means no Firefox profiles. One that macOS refuses (or can't be read) is a source saying so.
            return BrowserHistoryReader.isPermissionDenied(error) || fm.fileExists(atPath: ini.path)
                ? [needsFullDiskAccess(.firefox, base: base)] : []
        }
        var sections: [[String: String]] = []
        var isProfile = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isProfile = line.lowercased().hasPrefix("[profile")
                if isProfile { sections.append([:]) }
            } else if isProfile, let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1][key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let found = sections.compactMap { section -> (ImportSource, Bool)? in
            guard let path = section["Path"], !path.isEmpty else { return nil }
            let directory = section["IsRelative"] == "0"
                ? URL(filePath: path, directoryHint: .isDirectory)
                : base.appending(path: path, directoryHint: .isDirectory)
            let history = directory.appending(path: "places.sqlite")
            let prefs = directory.appending(path: "prefs.js")
            let search = directory.appending(path: "search.json.mozlz4")
            let hasHistory = fm.fileExists(atPath: history.path)
            let hasSettings = fm.fileExists(atPath: prefs.path) || fm.fileExists(atPath: search.path)
            func exists(_ name: String) -> Bool { fm.fileExists(atPath: directory.appending(path: name).path) }
            let hasOpenTabs = exists("sessionstore.jsonlz4") || exists("sessionstore-backups/recovery.jsonlz4")
                || exists("sessionstore-backups/previous.jsonlz4")
            let hasSiteSettings = exists("permissions.sqlite") || exists("content-prefs.sqlite")
            let hasExtensions = exists("extensions.json")
            guard hasHistory || hasSettings || hasOpenTabs || hasSiteSettings || hasExtensions else { return nil }
            let source = ImportSource(
                browser: .firefox, profileName: section["Name"] ?? directory.lastPathComponent, directory: directory,
                historyFile: history, settingsFile: prefs, searchFile: search, hasHistory: hasHistory, hasSettings: hasSettings,
                bookmarksFile: history, hasBookmarks: hasHistory, hasOpenTabs: hasOpenTabs,
                hasSiteSettings: hasSiteSettings, hasExtensions: hasExtensions
            )
            return (source, section["Default"] == "1")
        }
        // The profile Firefox opens first, then the rest in file order.
        return found.filter(\.1).map(\.0) + found.filter { !$0.1 }.map(\.0)
    }
}
