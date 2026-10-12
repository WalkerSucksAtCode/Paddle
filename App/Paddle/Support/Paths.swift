import Foundation
import PaddleCore

/// Everything user-editable lives in `~/Library/Application Support/Paddle/`.
enum Paths {
    static let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Paddle", directoryHint: .isDirectory)

    static let config = support.appending(path: "config.json")
    static let userCSS = support.appending(path: "user.css")
    static let userScripts = support.appending(path: "userscripts", directoryHint: .isDirectory)
    static let filters = support.appending(path: "filters", directoryHint: .isDirectory)
    static let userFilters = support.appending(path: "user-filters.txt")
    static let session = support.appending(path: "session.json")
    /// Each saved tab's back/forward state, `<tab id>.state`, named from session.json (`SessionStore`).
    static let sessions = support.appending(path: "sessions", directoryHint: .isDirectory)
    static let history = support.appending(path: "history.sqlite")
    static let bookmarks = support.appending(path: "bookmarks.json")
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
