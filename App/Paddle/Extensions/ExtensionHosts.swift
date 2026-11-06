import Foundation
import os
import PaddleCore
import WebKit

/// One extension host per profile. Call sites acting on a window, tab or extension context use that profile's host;
/// app-level UI (the Extensions menu, Settings > Extensions, the Develop menu) uses the front window's.
extension AppModel {
    /// The default profile's host, then the other profiles' hosts made so far.
    var extensionHosts: [ExtensionHost] {
        [extensions] + profileExtensionHosts.keys.sorted().compactMap { profileExtensionHosts[$0] }
    }

    /// The host of a profile, made (prepared, told about the profile's open windows, and loading) on first use. Nil
    /// for an id that isn't a profile in profiles.json (a deleted one), so nothing of it is ever made again.
    func extensions(for profile: ProfileID) -> ExtensionHost? {
        if profile == ProfileStore.defaultID { return extensions }
        if let host = profileExtensionHosts[profile] { return host }
        guard profiles.contains(profile), UUID(uuidString: profile) != nil else { return nil }
        let host = ExtensionHost(profile: profile)
        profileExtensionHosts[profile] = host
        host.prepare(config: config)
        for window in windows where !window.model.isPrivate && window.model.profileID == profile { host.windowOpened(window) }
        let current = config
        Task { await host.loadAll(config: current) }
        return host
    }

    /// The host of a profile if it has been made; window and tab events use this, so they never make one.
    func existingExtensions(for profile: ProfileID) -> ExtensionHost? {
        profile == ProfileStore.defaultID ? extensions : profileExtensionHosts[profile]
    }

    /// The host that runs `context`; nil when no host runs it any more.
    func extensionHost(owning context: WKWebExtensionContext) -> ExtensionHost? {
        extensionHosts.first { host in host.loaded.contains { $0.context === context } }
            ?? extensionHosts.first { $0.controller != nil && $0.controller === context.webExtensionController }
    }

    /// The front window's profile host (the default one for a private window or no window): the Extensions menu,
    /// Settings > Extensions, the Develop menu's background pages.
    var frontExtensions: ExtensionHost {
        frontWindow.flatMap { extensions(for: $0.model.profileID) } ?? extensions
    }

    /// Reconciles every profile's host (a store install or update changed `extensions/`). `reloading`: folders whose
    /// files were replaced, unloaded and loaded again wherever they run.
    func reconcileExtensions(reloading: Set<String> = []) async {
        let overlays = OverlayMemo()
        for host in extensionHosts { await host.reconcile(config: config, reloading: reloading, overlayMemo: overlays) }
    }

    /// The hosts whose answers a store update of `folder` must respect: the default profile's (as before profiles)
    /// and every other profile that has answered for it.
    private func hostsAnswering(_ folder: String) -> [ExtensionHost] {
        [extensions] + profileExtensionHosts.keys.sorted().compactMap { profileExtensionHosts[$0] }.filter { $0.hasAnswers(for: folder) }
    }

    /// What a newer version of `folder` asks about, over every profile that answered for it. Nil while one of those
    /// permission files is unreadable.
    func extensionUpdateAsks(
        folder: String, name: String, requested: ExtensionPermissionDiff.Requests, added: ExtensionPermissionDiff.Requests
    ) -> ExtensionPermissionDiff.Requests? {
        var asks: ExtensionPermissionDiff.Requests = ([], [])
        for host in hostsAnswering(folder) {
            guard let one = host.updateAsks(folder: folder, name: name, requested: requested, added: added) else { return nil }
            asks.permissions.formUnion(one.permissions)
            asks.hosts.formUnion(one.hosts)
        }
        return asks
    }

    /// An allowed update's grants, recorded in every profile that answered for the folder.
    func recordExtensionUpdateAllowed(
        folder: String, name: String, version: String, requested: ExtensionPermissionDiff.Requests, asks: ExtensionPermissionDiff.Requests
    ) {
        for host in hostsAnswering(folder) {
            host.recordUpdateAllowed(folder: folder, name: name, version: version, requested: requested, asks: asks)
        }
    }

    /// A new folder installed from a window of `profile` (not the default): on in that profile (profiles.json) and
    /// off in the default profile (`extensions.<folder>` false in config.json), so it runs only where it was installed.
    /// The config write is tried twice — a setting saved while the install ran conflicts with the first attempt, and
    /// the retry applies the turn-off on top of it. Still failing, the folder stays on in the default profile
    /// (unlisted folders default on) and the log says so plainly.
    func installOnlyInProfile(folder: String, profile: ProfileID) async {
        guard profile != ProfileStore.defaultID, profiles.contains(profile) else { return }
        profiles.setExtension(folder: folder, on: true, for: profile)
        let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")
        for attempt in 0..<2 {
            let disk: Data
            do {
                disk = try Self.readConfigFile(Paths.config.resolvingSymlinksInPath())
            } catch {
                log.error("extensions.\(folder, privacy: .private) not turned off: \(error.localizedDescription, privacy: .public)")
                return
            }
            switch await writeConfig([ConfigChange("extensions", folder, .bool(false))], base: disk) {
            case .written: return
            case .conflict(let paths):
                if attempt == 0 { continue }
                log.error("extensions.\(folder, privacy: .private) not turned off: changed on disk (\(paths.count) paths); it runs in the default profile too until turned off in Settings > Extensions")
            case .failed(let reason):
                log.error("extensions.\(folder, privacy: .private) not turned off: \(reason, privacy: .public); it runs in the default profile too until turned off in Settings > Extensions")
                return
            }
        }
    }

    /// A profile is being deleted (its windows are closed): its host unloads every extension and is dropped.
    func dropExtensions(profile: ProfileID) {
        guard profile != ProfileStore.defaultID, let host = profileExtensionHosts.removeValue(forKey: profile) else { return }
        host.shutDown()
    }

    /// Deletes a deleted profile's extension storage (`storage.local` and the like), which WebKit files under the
    /// profile's controller identifier. Only from `ProfileStore.delete`.
    func removeExtensionStorage(profile: ProfileID) {
        guard profile != ProfileStore.defaultID else { return }
        let folder = Paths.webExtensionStorage(profile: profile)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Logger(subsystem: "com.walker.Paddle", category: "extensions")
                .error("deleted profile's extension storage not removed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension BrowserModel {
    /// The extension host of this window's profile (the default one for a private window), once it has been made.
    var extensionHost: ExtensionHost? { AppModel.shared.existingExtensions(for: profileID) }
}

/// The overlay `ExtensionOverlay.make` gave each folder during one reconcile pass. Every profile's host reconciles
/// with the same memo, so a folder is fingerprinted once per pass rather than once per profile. Made by
/// `AppModel.reconcileExtensions` and dropped when the pass ends; nothing carries over to the next pass.
final class OverlayMemo {
    private var made: [String: (root: URL, plan: CompatPlan, result: Result<ExtensionOverlayResult?, any Error>)] = [:]

    /// What this pass already made for `name` from `root` with `plan`, if that is what it was asked for.
    func result(for name: String, root: URL, plan: CompatPlan) -> Result<ExtensionOverlayResult?, any Error>? {
        guard let entry = made[name], entry.root == root, entry.plan == plan else { return nil }
        return entry.result
    }

    func store(_ result: Result<ExtensionOverlayResult?, any Error>, for name: String, root: URL, plan: CompatPlan) {
        made[name] = (root, plan, result)
    }
}
