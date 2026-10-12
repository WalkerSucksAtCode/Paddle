import CryptoKit
import Foundation
import os
import PaddleCore
import WebKit

/// Shared WebKit setup for every tab: one content controller (user scripts, user CSS, block lists),
/// the default website data store (cookies and logins persist; private windows get a non-persistent one), and the
/// user agent.
@Observable
final class WebEnvironment {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "web")

    @ObservationIgnored let contentController = WKUserContentController()
    @ObservationIgnored let dataStore = WKWebsiteDataStore.default()
    @ObservationIgnored private(set) var config = PaddleConfig()
    @ObservationIgnored private var installedRuleLists: [String: WKContentRuleList] = [:]
    @ObservationIgnored private lazy var ruleStore: WKContentRuleListStore =
        WKContentRuleListStore(url: Paths.compiledRules) ?? .default()
    /// Set by `ExtensionHost` once at least one extension is allowed to run; every web view made after that carries
    /// it (popups copy the configuration, so they inherit it too). nil costs nothing: WebKit's extension machinery
    /// is never started.
    @ObservationIgnored var extensionController: WKWebExtensionController?

    /// One line per block list for the Content Blocking status item, e.g. "easylist: 61,204 rules".
    private(set) var blockerStatus: [String] = []
    private(set) var isUpdatingFilters = false

    /// `Version/27.0 Safari/605.1.15` from the installed Safari, so sites treat Paddle as Safari.
    static let safariApplicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "27.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    var applicationName: String {
        config.userAgentSuffix.isEmpty ? Self.safariApplicationName : config.userAgentSuffix
    }

    /// One non-persistent data store shared by every private window, made with the first one and dropped when the
    /// last one closes (`endPrivateSession`), so the next private window starts with no cookies or storage.
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?

    /// Web views of private windows get the private store and, unless `extensions` (config `extensionsInPrivate`),
    /// no extension controller. Content blockers, user CSS and userscripts are the same as everywhere.
    func makeConfiguration(isPrivate: Bool, extensions: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.userContentController = contentController
        if isPrivate {
            let store = privateDataStore ?? .nonPersistent()
            privateDataStore = store
            c.websiteDataStore = store
        } else {
            c.websiteDataStore = dataStore
        }
        c.applicationNameForUserAgent = applicationName
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.setValue(config.developerTools, forKey: "developerExtrasEnabled")
        c.allowsAirPlayForMediaPlayback = true
        c.webExtensionController = extensions ? extensionController : nil
        Self.enableWebFeatures(c.preferences)
        return c
    }

    /// The last private window closed: forget the private store. Its web views are gone (closing a window sleeps
    /// every tab), so WebKit discards its cookies, caches and storage with it.
    func endPrivateSession() {
        privateDataStore = nil
    }

    /// WebKit features Chrome and Firefox ship on that WebKit ships off: `requestIdleCallback`, which extensions
    /// (Proton Pass's form detector) and some sites call without a fallback. Private `_setEnabled:forFeature:`,
    /// guarded; without it nothing changes (the extension prelude has a stand-in).
    private static func enableWebFeatures(_ preferences: WKPreferences) {
        let listSelector = NSSelectorFromString("_features"), setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: listSelector), preferences.responds(to: setSelector),
              let features = (WKPreferences.self as AnyObject).perform(listSelector)?.takeUnretainedValue() as? [NSObject]
        else { return }
        typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setFeature = unsafeBitCast(preferences.method(for: setSelector), to: SetFeature.self)
        for feature in features where (feature.value(forKey: "key") as? String) == "RequestIdleCallbackEnabled" {
            setFeature(preferences, setSelector, true, feature)
        }
    }

    /// The configuration extension pages (popups, options pages, backgrounds) derive from: the browsing data store,
    /// the user agent and developer extras, and nothing else. No shared content controller, so user.css, userscripts
    /// and block lists never reach extension pages.
    func makeExtensionPageBaseConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.applicationNameForUserAgent = applicationName
        c.preferences.setValue(config.developerTools, forKey: "developerExtrasEnabled")
        Self.enableWebFeatures(c.preferences)
        return c
    }

    /// Applies a (re)loaded config. New tabs pick up user agent changes; scripts and CSS apply on next load.
    func apply(_ config: PaddleConfig) {
        self.config = config
        reloadUserScripts()
    }

    // MARK: - User CSS and scripts

    func reloadUserScripts() {
        contentController.removeAllUserScripts()

        if let css = try? String(contentsOf: Paths.userCSS, encoding: .utf8), Self.hasRealCSS(css) {
            contentController.addUserScript(WKUserScript(
                source: Self.styleInjection(css),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            ))
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.userScripts, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "js" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let script = UserScript(fileName: file.lastPathComponent, source: source)
            contentController.addUserScript(WKUserScript(
                source: script.wrappedSource,
                injectionTime: script.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: script.mainFrameOnly,
                in: script.isolated ? .defaultClient : .page
            ))
            log.info("user script loaded: \(script.name, privacy: .public)")
        }
    }

    private static func hasRealCSS(_ css: String) -> Bool {
        let withoutComments = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return !withoutComments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func styleInjection(_ css: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [css])) ?? Data("[\"\"]".utf8)
        let literal = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return """
        (function () {
          const add = () => {
            const style = document.createElement("style");
            style.id = "paddle-user-css";
            style.textContent = \(literal);
            (document.head || document.documentElement).appendChild(style);
          };
          if (document.documentElement) add(); else document.addEventListener("DOMContentLoaded", add);
        })();
        """
    }

    // MARK: - Content blocking

    /// Installs compiled block lists: the downloaded file of each list in `config.filterLists`, then
    /// `user-filters.txt`. Other files in `filters/` (lists since removed from config) are left on disk and not
    /// used, so a removed list stops blocking at the next reload. Lists already compiled for the same file
    /// contents load from cache in milliseconds; changed or new lists compile in the background and apply to later
    /// page loads. Every list gets a status line, including empty and failed ones.
    func loadContentBlockers() async {
        guard config.contentBlocking else {
            contentController.removeAllContentRuleLists()
            installedRuleLists.removeAll()
            blockerStatus = ["Off (contentBlocking is false in config.json)"]
            return
        }

        var status: [String] = []
        var sources: [URL] = []
        for list in config.filterLists {
            guard let file = FilterUpdatePolicy.fileName(forList: list) else {
                status.append("\(list): ignored, not an https URL")
                continue
            }
            let url = Paths.filters.appending(path: file)
            // Lists share a file in `filters/` when their URLs end in the same name; only the first is used.
            guard !sources.contains(url) else {
                status.append("\(list): ignored, same file name as an earlier list")
                continue
            }
            sources.append(url)
        }
        sources.append(Paths.userFilters)

        var wanted: [String: WKContentRuleList] = [:]
        for file in sources {
            let name = file.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                let exists = FileManager.default.fileExists(atPath: file.path)
                status.append("\(name): \(exists ? "unreadable (not UTF-8 text)" : file == Paths.userFilters ? "no file" : "not downloaded yet")")
                continue
            }
            let digest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let identifier = "\(name).\(digest)"

            var cached = installedRuleLists[identifier]
            if cached == nil { cached = try? await ruleStore.contentRuleList(forIdentifier: identifier) }
            if let cached {
                wanted[identifier] = cached
                status.append(await cachedSummary(identifier: identifier, text: text).statusLine(name: name, cached: true))
                continue
            }

            let (result, summary) = await Task.detached(priority: .utility) {
                let result = FilterListConverter.convert(text)
                return (result, RuleListSummary(text: text, result: result))
            }.value
            // WebKit refuses a list with no rules ("Empty extension"); there is nothing to install.
            guard summary.ruleCount > 0 else {
                status.append(summary.statusLine(name: name, cached: false))
                continue
            }
            do {
                if let list = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: result.json) {
                    wanted[identifier] = list
                    saveSummary(summary, identifier: identifier)
                    status.append(summary.statusLine(name: name, cached: false))
                    log.info("compiled \(identifier, privacy: .public): \(result.ruleCount) rules, \(result.skippedLines) lines skipped")
                }
            } catch {
                let reason = RuleListSummary.compileFailureReason(
                    helpAnchor: (error as NSError).userInfo[NSHelpAnchorErrorKey] as? String,
                    fallback: error.localizedDescription
                )
                status.append("\(name): failed to compile (\(reason))")
                log.error("compile \(identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        for (identifier, list) in installedRuleLists where wanted[identifier] == nil { contentController.remove(list) }
        for (identifier, list) in wanted where installedRuleLists[identifier] == nil { contentController.add(list) }
        installedRuleLists = wanted
        blockerStatus = status
        await removeStaleCompiledLists(keeping: Set(wanted.keys))
    }

    /// The sidecar `compiled-rules/<identifier>.json` written when the list was compiled.
    private static func summaryURL(_ identifier: String) -> URL {
        Paths.compiledRules.appending(path: "\(identifier).json")
    }

    private func saveSummary(_ summary: RuleListSummary, identifier: String) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: Self.summaryURL(identifier), options: .atomic)
    }

    /// The saved counts for a cached list. Lists compiled before sidecars existed are converted once more (not
    /// recompiled) to recover them.
    private func cachedSummary(identifier: String, text: String) async -> RuleListSummary {
        if let data = try? Data(contentsOf: Self.summaryURL(identifier)),
           let summary = try? JSONDecoder().decode(RuleListSummary.self, from: data) {
            return summary
        }
        let summary = await Task.detached(priority: .utility) {
            RuleListSummary(text: text, result: FilterListConverter.convert(text))
        }.value
        saveSummary(summary, identifier: identifier)
        return summary
    }

    /// Drops compiled lists and their sidecars that no current list uses.
    private func removeStaleCompiledLists(keeping: Set<String>) async {
        if let identifiers = await ruleStore.availableIdentifiers() {
            for identifier in identifiers where !keeping.contains(identifier) {
                try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.compiledRules, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !keeping.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// What one Update Filter Lists run did: a line per list, and how many lists were written or failed.
    struct FilterUpdateReport {
        var lines: [String] = []
        var written = 0
        var failures = 0
        /// Another update was already running, so this one did nothing.
        var skipped = false
        var text: String { lines.joined(separator: "\n") }
    }

    /// Lists whose last automatic or manual download failed, keyed by file name, e.g.
    /// "easyprivacy: update failed (404), last downloaded 9 days ago". Shown under Content blocking in Activity.
    private(set) var filterUpdateProblems: [String: String] = [:]

    /// Downloads `lists` (default: every list in `config.filterLists`) into `filters/`, then recompiles if any
    /// list was written. Used by Paddle > Update Filter Lists and by the automatic update (`filterUpdateDays`).
    func updateFilterLists(_ lists: [String]? = nil) async -> FilterUpdateReport {
        guard !isUpdatingFilters else { return FilterUpdateReport(lines: ["Already updating."], skipped: true) }
        isUpdatingFilters = true
        defer { isUpdatingFilters = false }

        let configured = Set(config.filterLists.compactMap(FilterUpdatePolicy.fileName(forList:)))
        filterUpdateProblems = filterUpdateProblems.filter { configured.contains($0.key) }

        var report = FilterUpdateReport()
        for string in lists ?? config.filterLists {
            guard let file = FilterUpdatePolicy.fileName(forList: string), let url = URL(string: string) else {
                report.lines.append("Skipped \(string): not an https URL")
                report.failures += 1
                continue
            }
            let name = (file as NSString).deletingPathExtension
            let destination = Paths.filters.appending(path: file)
            func failed(_ reason: String) {
                report.lines.append("\(name): \(reason)")
                report.failures += 1
                filterUpdateProblems[file] = "\(name): update failed (\(reason)), \(Self.downloadedAge(destination))"
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { failed("HTTP \(status)"); continue }
                guard let text = String(data: data, encoding: .utf8), text.hasPrefix("[Adblock") || text.hasPrefix("!")
                else { failed("not a filter list"); continue }
                try data.write(to: destination, options: .atomic)
                report.lines.append("\(name): \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                report.written += 1
                filterUpdateProblems[file] = nil
            } catch {
                failed(error.localizedDescription)
            }
        }
        // Nothing new on disk means the installed rule lists are already current.
        if report.written > 0 { await loadContentBlockers() }
        return report
    }

    /// "last downloaded 3 days ago", or "never downloaded" when the list's file does not exist.
    private static func downloadedAge(_ file: URL) -> String {
        guard let date = modificationDate(file) else { return "never downloaded" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        return days <= 0 ? "last downloaded today" : "last downloaded \(days) day\(days == 1 ? "" : "s") ago"
    }

    private static func modificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The configured lists due for an automatic download: each judged on its own file in `filters/`.
    func filterListsDue(now: Date) -> [String] {
        FilterUpdatePolicy.dueLists(config.filterLists, now: now, days: config.filterUpdateDays) { file in
            Self.modificationDate(Paths.filters.appending(path: file))
        }
    }
}

private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String]? {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0) }
        }
    }
}
