import Foundation
import PaddleCore

/// Everything user-editable lives in `~/Library/Application Support/Paddle/`.
enum Paths {
    static let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Paddle", directoryHint: .isDirectory)

    /// The control bridge's Unix socket (`ControlBridge`), present only while `controlBridge` is on. A socket path
    /// must fit `sun_path` (104 bytes); a long home folder falls back to `<temp dir>/paddle-<uid>/control.sock`
    /// (the parent is made 0700). `paddle-mcp` repeats this rule in `App/PaddleMCP/main.swift`.
    static let controlSocket: URL = {
        // Its own folder, so making the socket's parent owner-only (0700) never touches the support folder itself.
        let inSupport = support.appending(path: "bridge", directoryHint: .isDirectory).appending(path: "control.sock")
        if inSupport.path.utf8.count < 104 { return inSupport }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "paddle-\(getuid())", directoryHint: .isDirectory).appending(path: "control.sock")
    }()
    static let config = support.appending(path: "config.json")
    static let userCSS = support.appending(path: "user.css")
    static let userScripts = support.appending(path: "userscripts", directoryHint: .isDirectory)
    /// Chrome color themes, `<name>.json` (`ThemeStore`).
    static let themes = support.appending(path: "themes", directoryHint: .isDirectory)
    static let filters = support.appending(path: "filters", directoryHint: .isDirectory)
    static let userFilters = support.appending(path: "user-filters.txt")
    static let session = support.appending(path: "session.json")
    /// Each saved tab's back/forward state, `<tab id>.state`, named from session.json (`SessionStore`).
    static let sessions = support.appending(path: "sessions", directoryHint: .isDirectory)
    static let history = support.appending(path: "history.sqlite")
    /// The profiles (`ProfileStore`).
    static let profilesFile = support.appending(path: "profiles.json")
    /// Everything Paddle itself keeps for a non-default profile, deleted with the profile.
    static func profileFolder(_ id: String) -> URL {
        support.appending(path: "profiles", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
    }
    /// A non-default profile's browsing history; the default profile's is `history`.
    static func profileHistory(_ id: String) -> URL { profileFolder(id).appending(path: "history.sqlite") }
    static let bookmarks = support.appending(path: "bookmarks.json")
    /// Pinned New Tab page sites and hidden Frequently visited hosts (`NewTabStore`).
    static let newTab = support.appending(path: "newtab.json")
    static let favicons = support.appending(path: "favicons", directoryHint: .isDirectory)
    static let compiledRules = support.appending(path: "compiled-rules", directoryHint: .isDirectory)
    /// Unpacked WebExtensions, one folder each.
    static let extensions = support.appending(path: "extensions", directoryHint: .isDirectory)
    /// Per-extension permission answers, keyed by folder name.
    static let extensionPermissions = support.appending(path: "extension-permissions.json")
    /// Per-install salt for extension ids; created once.
    static let extensionSalt = support.appending(path: "extension-id-salt")
    /// Patched clones of extensions that need the compat prelude, one folder per extension, remade when the source changes.
    static let extensionOverlays = support.appending(path: "extension-overlays", directoryHint: .isDirectory)
    /// When each extension folder first ran, for the synthesised `runtime.onInstalled` "install" (`ExtensionInstalls`).
    static let extensionInstalls = support.appending(path: "extension-installs.json")
    /// Where each store-installed extension folder came from (`ExtensionSources`), written by `StoreInstaller`.
    static let extensionSources = support.appending(path: "extension-sources.json")
    /// WebKit's own storage for extensions (`storage.local` and the like), one folder per context
    /// `uniqueIdentifier`, under the default controller configuration. Paddle only moves a folder when an
    /// extension's id changes (`ExtensionHost.moveStorage`); WebKit owns what is inside.
    static let webExtensionStorage = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/WebKit/\(Bundle.main.bundleIdentifier ?? "com.walker.Paddle")/WebExtensions/Default", directoryHint: .isDirectory)
    /// The same for a profile: `webExtensionStorage` for the default one; another profile's controller files its
    /// extensions' storage next to it under the profile's id (matched without regard to case, as WebKit writes it).
    static func webExtensionStorage(profile: String) -> URL {
        guard profile != ProfilesFile.defaultID else { return webExtensionStorage }
        let parent = webExtensionStorage.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let name = names.first { $0.caseInsensitiveCompare(profile) == .orderedSame } ?? profile.lowercased()
        return parent.appending(path: name, directoryHint: .isDirectory)
    }

    /// Creates the folder layout and starter files on first launch. Never overwrites existing files.
    static func ensure() {
        let fm = FileManager.default
        for dir in [support, userScripts, filters, compiledRules, favicons, extensions] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // An empty object: every key falls back to its default, so the file only ever holds what the user changed.
        writeIfMissing(config, "{}\n")
        writeIfMissing(userCSS, """
        /* Paddle user stylesheet: applied to every page. Paddle > Reload Config to apply changes.
           Example:
           @media (prefers-color-scheme: dark) { ::selection { background: #355; } }
        */

        """)
        writeIfMissing(userFilters, """
        ! Your own blocking rules, Adblock Plus syntax. Paddle > Reload Config to apply.
        ! ||annoying-widget.example^         block a host
        ! example.com##.newsletter-popup     hide an element on one site
        ! @@||mybank.example^$document       exception: no blocking on that site, in every list (EasyList too)

        """)
    }

    private static func writeIfMissing(_ url: URL, _ text: String) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data(text.utf8).write(to: url)
    }
}
