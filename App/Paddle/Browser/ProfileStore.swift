import AppKit
import Foundation
import os
import PaddleCore
import WebKit

typealias ProfileID = String

/// The profiles in profiles.json. A plain file you can edit by hand (Paddle > Reload Config re-reads it). If the
/// file exists but can't be read, Paddle never writes it, so nothing is lost; the default profile still works.
@Observable
final class ProfileStore {
    static let defaultID: ProfileID = ProfilesFile.defaultID

    private var file = ProfilesFile()
    /// Set when profiles.json exists but can't be read.
    private(set) var loadError: String?
    private let log = Logger(subsystem: "com.walker.Paddle", category: "profiles")

    /// Every profile, the default one first.
    var all: [Profile] { file.profiles }
    /// More than one profile: the chrome then shows which one a window is in.
    var hasSeveral: Bool { file.profiles.count > 1 }

    /// The profile with this id; an unknown id is the default profile.
    func profile(id: ProfileID) -> Profile {
        file.profile(id: id) ?? file.profiles[0]
    }

    func contains(_ id: ProfileID) -> Bool { file.profile(id: id) != nil }

    /// Reads profiles.json (at launch and on Reload Config).
    func load() {
        guard FileManager.default.fileExists(atPath: Paths.profilesFile.path) else {
            file = ProfilesFile()
            loadError = nil
            return
        }
        do {
            file = try ProfilesFile.decode(Data(contentsOf: Paths.profilesFile))
            loadError = nil
        } catch {
            loadError = "profiles.json: \(PaddleConfig.describe(error))"
            log.error("\(self.loadError ?? "", privacy: .public)")
        }
    }

    private func save() {
        guard loadError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try file.encoded().write(to: Paths.profilesFile.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            log.error("profiles save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a profile. Nil when profiles.json is unreadable (it is not overwritten).
    @discardableResult
    func add(name: String, symbol: ProfileSymbol) -> Profile? {
        guard loadError == nil else { return nil }
        let profile = file.add(name: name, symbol: symbol)
        save()
        return profile
    }

    /// False, with nothing changed, when the name is empty or another profile has it.
    @discardableResult
    func rename(id: ProfileID, to name: String) -> Bool {
        guard loadError == nil, file.rename(id: id, to: name) else { return false }
        save()
        return true
    }

    func setSymbol(_ symbol: ProfileSymbol, for id: ProfileID) {
        guard loadError == nil, file.setSymbol(symbol, for: id) else { return }
        save()
    }

    /// Sets (or with nil removes) one of a profile's own settings (`ProfileOverrides`), then applies it.
    @discardableResult
    func setOverride(_ path: [String], to value: JSONValue?, for id: ProfileID) -> Bool {
        guard loadError == nil, file.setOverride(path, to: value, for: id) else { return false }
        save()
        AppModel.shared.profileSettingsEdited()
        return true
    }

    /// Turns the extension in `folder` on or off for a non-default profile.
    func setExtension(folder: String, on: Bool, for id: ProfileID) {
        guard loadError == nil, file.setExtension(folder: folder, on: on, for: id) else { return }
        save()
    }

    /// Deletes a profile and everything Paddle keeps for it: closes its windows, unloads its extensions, removes its
    /// WebKit data store (cookies, logins, storage, cache), its extension storage and its profiles/<id>/ folder
    /// (history, extension permission answers), then saves. False, with the
    /// profile kept, when WebKit couldn't remove the data store, so a retry stays possible.
    @discardableResult
    func delete(id: ProfileID) async -> Bool {
        guard id != Self.defaultID, contains(id), loadError == nil else { return false }
        let app = AppModel.shared
        app.closeWindows(inProfile: id)
        app.dropExtensions(profile: id)
        app.forgetHistoryStore(profile: id)
        app.sessionPermissions[id] = nil
        guard await app.web.removeDataStore(for: id) else { return false }
        app.removeExtensionStorage(profile: id)
        do {
            let folder = Paths.profileFolder(id)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        } catch {
            log.error("profile folder removal failed: \(error.localizedDescription, privacy: .public)")
        }
        file.remove(id: id)
        save()
        // Its cached config (and its historyDays, which `historyEnabled` counts) goes too.
        app.profileSettingsEdited()
        log.info("profile deleted")
        return true
    }
}
