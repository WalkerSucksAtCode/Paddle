import Foundation
import PaddleCore

/// Settings > Extensions' writes and its memory readout.
extension SettingsModel {
    /// On removes the folder's entry (folders not listed are on); off writes `false`. Saving reconciles the
    /// extensions folder: off unloads it, on loads it with the answers already in the permissions file, so only an
    /// extension never answered for is asked about.
    func setExtension(_ folder: String, enabled: Bool) async {
        await save([ConfigChange("extensions", folder, enabled ? nil : .bool(false))])
    }

    /// One folder's toolbar button (`extensionToolbar.<folder>`); `pinned` is the default and removes the entry.
    func setToolbarPlacement(_ folder: String, _ placement: ExtensionToolbarPlacement) async {
        await save([ConfigChange("extensionToolbar", folder, placement == .pinned ? nil : .string(placement.rawValue))])
    }

    func setExtensionsInPrivate(_ on: Bool) async {
        await save([ConfigChange("extensionsInPrivate", .bool(on))])
    }

    /// One folder's "Allow in private windows" (`extensionCompat.<folder>.private`). A value equal to the global switch
    /// removes the field, so the folder follows `extensionsInPrivate` again.
    func setExtensionInPrivate(_ folder: String, _ on: Bool) async {
        await save([ConfigChange(path: ["extensionCompat", folder, "private"], value: on == file.extensionsInPrivate ? nil : .bool(on))])
    }
}

/// What the running extensions cost, measured while the Extensions pane is shown.
struct ExtensionMemory: Equatable {
    struct Process: Equatable {
        var bytes: UInt64
        /// Other folders whose background page runs in the same process (the bytes are their total).
        var sharedWith: [String]
    }

    /// The Activity popover's Extensions row: every process hosting only extension pages (background pages and
    /// open popups).
    var total: UInt64 = 0
    /// Folder name to its background page's process; absent when WebKit didn't say (no background page running,
    /// or the private `_backgroundWebView` / `_webProcessIdentifier` calls are gone).
    var byFolder: [String: Process] = [:]

    /// Measures every process (whatever `showTabMemory` says), then finds each running extension's background page
    /// process.
    static func sample() -> ExtensionMemory {
        let app = AppModel.shared
        app.measureMemory()
        var result = ExtensionMemory(total: app.memoryBreakdown.extensions)
        var folders: [pid_t: [String]] = [:]
        for ext in app.extensions.loaded {
            guard let view = app.extensions.backgroundWebView(of: ext), let pid = ProcessMemory.pid(of: view) else { continue }
            folders[pid, default: []].append(ext.name)
        }
        for (pid, names) in folders {
            guard let bytes = ProcessMemory.footprint(of: pid) else { continue }
            for name in names {
                result.byFolder[name] = Process(bytes: bytes, sharedWith: names.filter { $0 != name }.sorted())
            }
        }
        return result
    }
}
