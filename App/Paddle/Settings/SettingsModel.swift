import AppKit
import Foundation
import PaddleCore
import SwiftUI

/// Settings' view of `config.json`: what the panes show, the bytes their edits are based on, and the banner. Lives
/// only while a Settings tab shows (`SettingsTabView`). Every save goes through `AppModel.writeConfig`, which refuses to
/// overwrite a key that changed on disk since `base` was read.
@Observable
final class SettingsModel {
    enum Banner: Equatable {
        /// config.json can't be read at all: it isn't JSON, its top level isn't an object, or the file can't be read.
        /// Values of the wrong type don't get here (see `decodeIssues`).
        case invalid(message: String)
        /// The file holds valid edits Paddle isn't running with yet.
        case unapplied
        /// A save was refused because these paths changed on disk; `pendingChanges` holds the user's edit.
        case conflict(paths: [[String]])
        case writeFailed(String)

        var text: String {
            switch self {
            case .invalid(let message):
                "config.json can't be read: \(message.hasSuffix(".") ? String(message.dropLast()) : message). "
                    + "Paddle keeps running on the last good settings."
            case .unapplied:
                "config.json has edits Paddle hasn't applied. Saving any change here applies them too."
            case .conflict(let paths):
                "config.json changed while you were editing; your change to \(paths.map { $0.joined(separator: ".") }.joined(separator: ", ")) wasn't saved."
            case .writeFailed(let message):
                "config.json couldn't be saved: \(message)"
            }
        }
    }

    /// The decoded file as last read or written here. Panes show these values, not `AppModel.config`, so a hand
    /// edit shows up even before it is applied.
    private(set) var file: PaddleConfig
    /// Values in `file`'s config.json that have the wrong type (or are entries or list items Paddle skips). Each uses
    /// its default in `file`; Settings > Advanced lists them with Reset or Remove where that drops only the bad value.
    private(set) var decodeIssues: [ConfigIssue] = []
    private(set) var banner: Banner? {
        didSet {
            guard banner != oldValue, let banner else { return }
            AccessibilityNotification.Announcement(banner.text).post()
        }
    }

    /// Controls that edit config.json are off while the file can't be read; Edit config.json… stays on.
    var controlsDisabled: Bool {
        if case .invalid = banner { return true }
        return false
    }

    /// The bytes edits are based on (what `file` was decoded from). Observed so Advanced's unknown-key and Tidy
    /// lists follow edits that don't change the decoded config.
    private(set) var base = Data()
    @ObservationIgnored private var baseStamp: ConfigStamp?
    /// The edit a conflict refused, for Save Mine.
    @ObservationIgnored private var pendingChanges: [ConfigChange] = []
    /// The last queued write. Each write waits for it before reading `base`, so back-to-back saves build on the
    /// bytes the previous one wrote instead of conflicting with Paddle's own write.
    @ObservationIgnored private var writeTail: Task<Void, Never>?

    /// The profile of the window this Settings tab is in: the Extensions pane's switches and the Sites pane's
    /// session answers and Clear Data act on it (`SettingsTabView` sets it).
    var profileID: ProfileID = ProfileStore.defaultID

    init() {
        file = AppModel.shared.config
        refresh(force: true)
    }

    // MARK: - Reading

    /// Re-reads config.json unless its stamp shows nothing changed since the last read or Paddle's own last write.
    /// A conflict or write-failure banner stays until the user answers it, unless the file became unreadable.
    func refresh(force: Bool = false) {
        let url = Paths.config.resolvingSymlinksInPath()
        let stamp = ConfigStamp(url)
        if !force, stamp == baseStamp { return }
        // Paddle's own write (from this window or elsewhere): already applied, so no banner and no re-read.
        if !force, let stamp, let written = AppModel.shared.lastConfigWrite, stamp == written.stamp {
            baseStamp = stamp
            base = written.data
            file = AppModel.shared.config
            decodeIssues = AppModel.shared.configWarnings
            setBanner(nil)
            return
        }
        let data: Data
        do {
            data = try AppModel.readConfigFile(url)
        } catch {
            setBanner(.invalid(message: error.localizedDescription))
            return
        }
        baseStamp = stamp
        base = data

        let decoded: (config: PaddleConfig, issues: [ConfigIssue])
        do {
            _ = try JSONSpans.scan(data)
            decoded = try AppModel.decodeConfigFile(data)
        } catch {
            setBanner(.invalid(message: Self.describe(error)))
            return
        }
        file = decoded.config
        decodeIssues = decoded.issues
        setBanner(file == AppModel.shared.config ? nil : .unapplied)
    }

    private func setBanner(_ state: Banner?) {
        switch banner {
        case .conflict, .writeFailed:
            if case .invalid = state { banner = state }
        default:
            banner = state
        }
    }

    // MARK: - Writing

    /// Saves `changes` against the bytes the panes were showing. Never reports success the file didn't get.
    /// `snapshot` is the `base` a draft started from (a text field being typed in): a hand edit to the same key
    /// since then is a conflict even though the watcher has re-read the file meanwhile.
    func save(_ changes: [ConfigChange], basedOn snapshot: Data? = nil) async {
        guard !changes.isEmpty else { return }
        await serialized { await self.write(changes, basedOn: snapshot) }
    }

    /// Saves the changes `build` makes from the bytes the write is based on, once every queued write is done: for
    /// an edit of one member of an entry (a `sites` field) that must keep an edit queued just before it.
    func save(building build: @escaping @MainActor (Data) -> [ConfigChange]) async {
        await serialized {
            let changes = build(self.base)
            guard !changes.isEmpty else { return }
            await self.write(changes)
        }
    }

    private func write(_ changes: [ConfigChange], basedOn snapshot: Data? = nil) async {
        guard !controlsDisabled else { return }
        switch await AppModel.shared.writeConfig(changes, base: snapshot ?? base) {
        case .written(let config, let issues, let data, let stamp):
            file = config
            decodeIssues = issues
            base = data
            baseStamp = stamp
            pendingChanges = []
            // Writing applied the whole file, hand edits included.
            banner = nil
        case .conflict(let paths):
            pendingChanges = changes
            banner = .conflict(paths: paths)
        case .failed(let message):
            banner = .writeFailed(message)
        }
    }

    // MARK: - Banner actions

    /// Apply Now: the Reload Config path, without its alert.
    func applyNow() async {
        await AppModel.shared.reloadConfig(showAlert: false)
        refresh(force: true)
    }

    /// Conflict > Use the File's Value: drops the refused edit and shows what is on disk.
    func useFilesValue() {
        pendingChanges = []
        banner = nil
        refresh(force: true)
    }

    /// Conflict > Save Mine: the refused edit again, this time based on the file as it is now.
    func saveMine() async {
        let changes = pendingChanges
        pendingChanges = []
        banner = nil
        refresh(force: true)
        await save(changes)
    }

    func dismissFailure() {
        banner = nil
        refresh(force: true)
    }

    // MARK: - Helpers

    /// Runs `body` after every write queued before it.
    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = writeTail
        let task = Task {
            await previous?.value
            await body()
        }
        writeTail = task
        await task.value
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case JSONSpans.ScanError.invalidJSON(let text): text
        case JSONSpans.ScanError.notAnObject: "it must be a JSON object: { ... }"
        case JSONSpans.ScanError.notUTF8: "it must be saved as UTF-8"
        default: PaddleConfig.describe(error)
        }
    }
}
