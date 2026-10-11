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
    static let history = support.appending(path: "history.sqlite")
    static let bookmarks = support.appending(path: "bookmarks.json")
    static let favicons = support.appending(path: "favicons", directoryHint: .isDirectory)
    static let compiledRules = support.appending(path: "compiled-rules", directoryHint: .isDirectory)

    /// Creates the folder layout and starter files on first launch. Never overwrites existing files.
    static func ensure() {
        let fm = FileManager.default
        for dir in [support, userScripts, filters, compiledRules, favicons] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: config.path), let data = try? PaddleConfig().encoded() {
            try? data.write(to: config)
        }
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
        ! @@||mybank.example^$document       turn blocking off for a site

        """)
    }

    private static func writeIfMissing(_ url: URL, _ text: String) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data(text.utf8).write(to: url)
    }
}
