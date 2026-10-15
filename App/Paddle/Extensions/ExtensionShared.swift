import AppKit
import os
import PaddleCore
import WebKit

/// What every profile's `ExtensionHost` shares, kept and written in this one place: the installed folders and their
/// scan, the id salt, the first-run records (`extension-installs.json`), the compat overlays on disk and the alert
/// queue. Also the app-wide hooks that exist once (the URL schemes, WebKit's permission notifications, the key
/// monitor), each handing its event to the host of the profile it belongs to.
final class ExtensionShared {
    static let shared = ExtensionShared()

    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")

    /// The per-install salt every extension id starts from (`extension-id-salt`).
    private(set) var salt = ""
    /// The folders in `extensions/` from the last scan.
    private(set) var entries: [ExtensionEntry] = []
    /// Folder name to why the scan couldn't use it.
    private(set) var scanProblems: [String: String] = [:]
    /// `extension-installs.json`, read (or seeded from the default profile's permissions file) once that file is readable.
    private(set) var installs: ExtensionInstalls?
    /// A pending rewrite of an overlay folder (the install reason cleared), by folder; the next remake waits for it.
    var overlayWrites: [String: Task<Void, Never>] = [:]
    /// Overlay folder work by folder name, one at a time per folder whichever host asked.
    private var overlayQueue: [String: Task<Void, Never>] = [:]
    /// Serializes every extension alert of every profile, one at a time.
    private var promptQueue: Task<Void, Never>?
    private var permissionObservers: [any NSObjectProtocol] = []
    /// Runs extension commands before the page sees the key.
    private var keyMonitor: Any?
    private var prepared = false

    /// Once per process, before the first host loads anything: schemes, salt, the first scan and the app-wide hooks.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        registerSchemes()
        salt = loadOrCreateSalt()
        rescan()
        observePermissionChanges()
        installKeyMonitor()
    }

    /// `chrome-extension` and `moz-extension` for the personas. WebKit throws (NSInternalInconsistencyException) when a
    /// context gets a base URL with an unregistered scheme, so this runs before any context exists.
    private func registerSchemes() {
        for scheme in [ExtensionIdentity.chromeScheme, ExtensionIdentity.firefoxScheme] {
            WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
        }
        log.info("extension schemes registered: \(ExtensionIdentity.chromeScheme, privacy: .public), \(ExtensionIdentity.firefoxScheme, privacy: .public)")
    }

    private func loadOrCreateSalt() -> String {
        if let existing = try? String(contentsOf: Paths.extensionSalt, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 32, trimmed.allSatisfy({ $0.isHexDigit }) { return trimmed.lowercased() }
            log.error("extension-id-salt is not 32 hex characters; making a new one (extension ids change)")
        }
        let salt = ExtensionIdentity.makeSalt()
        do {
            try Data(salt.utf8).write(to: Paths.extensionSalt, options: .atomic)
        } catch {
            log.error("extension-id-salt could not be written: \(error.localizedDescription, privacy: .public)")
        }
        return salt
    }

    /// Scans `extensions/` again. Reads only; every host then loads from the same list.
    func rescan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = ExtensionScan.scan(Paths.extensions, forbiddenRoots: [home, Paths.support])
        entries = result.entries
        scanProblems = result.problems
        StoreInstaller.shared.reloadSources()
        for (name, problem) in scanProblems { log.notice("\(name, privacy: .public): \(problem, privacy: .public)") }
    }

    // MARK: - First-run records

    /// Reads `extension-installs.json`, or makes it when it doesn't exist yet: every folder in `seed` (the folders
    /// with an answer in the permissions file) counts as already installed.
    func ensureInstalls(seed: some Sequence<String>) {
        guard installs == nil else { return }
        if let data = try? Data(contentsOf: Paths.extensionInstalls) {
            do {
                installs = try ExtensionInstalls.decode(data)
                return
            } catch {
                log.error("extension-installs.json unreadable (\(error.localizedDescription, privacy: .public)); remade from the permissions file")
            }
        }
        installs = ExtensionInstalls.seeded(folders: seed, now: Date())
        writeInstalls()
        log.info("extension-installs.json created: \(self.installs?.firstSeen.count ?? 0, privacy: .public) folders already installed")
    }

    /// The folder's first background run has had its install reason.
    func markSeen(folder: String) {
        if installs?.markSeen(folder: folder, now: Date()) == true { writeInstalls() }
    }

    private func writeInstalls() {
        guard let installs else { return }
        do {
            try installs.encoded().write(to: Paths.extensionInstalls, options: .atomic)
        } catch {
            log.error("extension-installs.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Overlays

    /// Overlays of folders that are gone from `extensions/` are deleted, with their first-seen and store records; the
    /// rest are checked against their source when their extension loads again. Run by the default profile's host only.
    func pruneOverlays() {
        // An unreadable or missing extensions/ folder (an unmounted volume, a permissions problem) looks empty: keep
        // the overlays and the first-seen records rather than treat every extension as removed.
        guard FileManager.default.isReadableFile(atPath: Paths.extensions.path) else {
            log.error("extensions/ unreadable; overlays and first-seen records kept")
            return
        }
        let folders = Set(entries.map(\.name)).union(scanProblems.keys)
        ExtensionOverlay.prune(in: Paths.extensionOverlays, keeping: Set(entries.map(\.name)))
        if installs?.prune(keeping: folders) == true { writeInstalls() }
        StoreInstaller.shared.pruneSources(keeping: folders)
    }

    /// Runs `body` after every overlay write for `folder` queued before it, so two profiles loading one extension never
    /// write its overlay folder at once.
    func overlayWork<T: Sendable>(_ folder: String, _ body: @escaping @MainActor () async -> T) async -> T {
        let previous = overlayQueue[folder]
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await body()
        }
        overlayQueue[folder] = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - Alerts

    /// Runs `body` after every alert queued before it, from any profile's host.
    func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = promptQueue
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await body()
        }
        promptQueue = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - App-wide hooks

    /// WebKit posts these when a grant or denial is added or removed, including `permissions.remove()` from the
    /// extension itself and the delegate prompts' results; the host that runs the context persists its current state.
    private func observePermissionChanges() {
        guard permissionObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ]
        for name in names {
            permissionObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue (`queue: .main`), so the context is used on its actor.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let context = object as? WKWebExtensionContext else { return }
                    AppModel.shared.extensionHost(owning: context)?.saveSnapshot(for: context)
                }
            })
        }
    }

    /// Extension commands run before the page and the window see the key, as in Chrome. The key window's profile
    /// decides whose extensions may take the key.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, inside the app's event dispatch.
            nonisolated(unsafe) let keyEvent = event
            let handled = MainActor.assumeIsolated {
                let browser = keyEvent.window?.windowController as? BrowserWindowController
                return browser?.model.extensionHost?.performCommandBeforeDispatch(keyEvent) ?? false
            }
            return handled ? nil : event
        }
    }
}
