import CryptoKit
import Foundation
import os
import PaddleCore
import WebKit

/// Shared WebKit setup for every tab: one content controller (user scripts, user CSS, block lists),
/// the default website data store (cookies and logins persist), and the user agent.
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

    func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.userContentController = contentController
        c.websiteDataStore = dataStore
        c.applicationNameForUserAgent = applicationName
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.setValue(config.developerTools, forKey: "developerExtrasEnabled")
        c.allowsAirPlayForMediaPlayback = true
        c.webExtensionController = extensionController
        return c
    }

    /// The configuration extension pages (popups, options pages, backgrounds) derive from: the browsing data store,
    /// the user agent and developer extras, and nothing else. No shared content controller, so user.css, userscripts
    /// and block lists never reach extension pages.
    func makeExtensionPageBaseConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.applicationNameForUserAgent = applicationName
        c.preferences.setValue(config.developerTools, forKey: "developerExtrasEnabled")
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

    /// Installs compiled block lists. Lists already compiled for the same file contents load from cache
    /// in milliseconds; changed or new lists compile in the background and apply to later page loads.
    func loadContentBlockers() async {
        guard config.contentBlocking else {
            contentController.removeAllContentRuleLists()
            installedRuleLists.removeAll()
            blockerStatus = ["Off (contentBlocking is false in config.json)"]
            return
        }

        var sources = ((try? FileManager.default.contentsOfDirectory(at: Paths.filters, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        sources.append(Paths.userFilters)

        var status: [String] = []
        var wanted: [String: WKContentRuleList] = [:]
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let digest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let identifier = "\(name).\(digest)"

            if let list = installedRuleLists[identifier] {
                wanted[identifier] = list
                status.append("\(name): active")
                continue
            }
            if let cached = try? await ruleStore.contentRuleList(forIdentifier: identifier) {
                wanted[identifier] = cached
                status.append("\(name): active")
                continue
            }

            let result = await Task.detached(priority: .utility) { FilterListConverter.convert(text) }.value
            guard result.ruleCount > 0 else { continue }
            do {
                if let list = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: result.json) {
                    wanted[identifier] = list
                    status.append("\(name): \(result.ruleCount.formatted()) rules\(result.truncated ? " (truncated)" : "")")
                    log.info("compiled \(identifier, privacy: .public): \(result.ruleCount) rules, \(result.skippedLines) lines skipped")
                }
            } catch {
                status.append("\(name): failed to compile (\(error.localizedDescription))")
                log.error("compile \(identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        contentController.removeAllContentRuleLists()
        for list in wanted.values { contentController.add(list) }
        installedRuleLists = wanted
        blockerStatus = status
        await removeStaleCompiledLists(keeping: Set(wanted.keys))
    }

    private func removeStaleCompiledLists(keeping: Set<String>) async {
        guard let identifiers = await ruleStore.availableIdentifiers() else { return }
        for identifier in identifiers where !keeping.contains(identifier) {
            try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
        }
    }

    /// Downloads every list in `config.filterLists` into `filters/`, then recompiles.
    func updateFilterLists() async -> String {
        guard !isUpdatingFilters else { return "Already updating." }
        isUpdatingFilters = true
        defer { isUpdatingFilters = false }

        var report: [String] = []
        for string in config.filterLists {
            guard let url = URL(string: string), url.scheme == "https" else {
                report.append("Skipped \(string): not an https URL")
                continue
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                      text.hasPrefix("[Adblock") || text.hasPrefix("!") else {
                    report.append("\(url.lastPathComponent): not a filter list")
                    continue
                }
                let name = url.deletingPathExtension().lastPathComponent
                try data.write(to: Paths.filters.appending(path: "\(name).txt"))
                report.append("\(name): \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
            } catch {
                report.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        await loadContentBlockers()
        return report.joined(separator: "\n")
    }

    var hasDownloadedFilters: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.filters, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.pathExtension == "txt" }
    }
}

private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String]? {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0) }
        }
    }
}
