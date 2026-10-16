import Foundation

/// One edit to `config.json`: a top-level key (`["maxAwakeTabs"]`), one entry of an object key such as
/// `shortcuts`, `extensions` or `siteUserAgents` (`["shortcuts", "nextTab"]`), or one field of a `sites` entry
/// (`["sites", "example.com", "zoom"]`). A `nil` value removes it.
public struct ConfigChange: Sendable, Equatable {
    public var path: [String]
    public var value: JSONValue?

    public init(path: [String], value: JSONValue?) {
        self.path = path
        self.value = value
    }

    public init(_ key: String, _ value: JSONValue?) { self.init(path: [key], value: value) }
    public init(_ key: String, _ entry: String, _ value: JSONValue?) { self.init(path: [key, entry], value: value) }
}

public enum ConfigWriteError: Error, Equatable, Sendable {
    /// The file on disk (or the copy the edit was based on) isn't a JSON object Paddle can edit.
    case invalidFile(String)
    /// A path with no key, more than three parts, or an entry inside a value that isn't an object.
    case badPath([String])
    /// These paths changed on disk after `base` was read; nothing was written.
    case conflict([[String]])
    /// The edit would leave a value Paddle can't use at a changed path (the text is that issue's path and message), or
    /// the edited bytes don't hold the intended values; nothing is written.
    case invalidResult(String)
}

/// Only the changed keys move; every other byte stays, so hand formatting and unknown keys survive a
/// Settings write.
public enum ConfigFile {
    /// Every key's default, as `encoded()` writes it. A value equal to this is left out of the file.
    public static let defaults: [String: JSONValue] = {
        // Encoding a struct of plain values can't fail; the force is here so a drift would show in tests.
        let data = try! PaddleConfig().encoded()
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return object.mapValues(JSONValue.init)
    }()

    /// The default for one entry of an object key, where there is one: an extension not listed is on.
    static func entryDefault(in key: String) -> JSONValue? { key == PaddleConfig.CodingKeys.extensions.rawValue ? .bool(true) : nil }

    /// The default of each field of a `sites` entry (`SitePolicy.defaults`), as the file writes it. Not `zoom`: its
    /// default is the `defaultZoom` key, so a zoom of 1 can be a real choice.
    static let siteFieldDefaults: [String: JSONValue] = [
        "javaScript": .bool(SitePolicy.defaults.javaScript),
        "autoplay": .string(SitePolicy.defaults.autoplay.rawValue),
        "contentBlocking": .bool(SitePolicy.defaults.contentBlocking),
        "location": .string(SitePolicy.defaults.location.rawValue),
        "notifications": .string(SitePolicy.defaults.notifications.rawValue),
        "httpsOnly": .bool(SitePolicy.defaults.httpsOnly),
        "popups": .bool(SitePolicy.defaults.popups),
    ]

    /// `disk` with `changes` applied, where `base` is what the editor read before the user made them.
    /// - A path whose disk value differs from its base value is a conflict: nothing is written.
    /// - A value equal to its default removes the key; an entry equal to its default is removed from its object,
    ///   and an object left empty is removed too.
    /// - Keys not in `changes` are never rewritten, defaults and unknown keys included.
    /// - A changed path can't land on a value Paddle would skip or can't use (a decode issue at, inside or above it),
    ///   else `.invalidResult`. Issues elsewhere in the file don't block the write.
    /// - The result must hold the intended values and decode to the same config, else `.invalidResult`.
    public static func apply(changes: [ConfigChange], base: Data, disk: Data) -> Result<Data, ConfigWriteError> {
        let diskSpans: JSONSpans
        let baseSpans: JSONSpans
        do {
            diskSpans = try JSONSpans.scan(disk)
            baseSpans = try JSONSpans.scan(base)
        } catch {
            return .failure(.invalidFile(describe(error)))
        }

        for change in changes {
            guard (1...3).contains(change.path.count) else { return .failure(.badPath(change.path)) }
            if change.path.count >= 2, let top = diskSpans.object[change.path[0]], top.objectValue == nil {
                return .failure(.badPath(change.path))
            }
            if change.path.count == 3, let entry = diskSpans.object[change.path[0]]?.objectValue?[change.path[1]],
               entry.objectValue == nil {
                return .failure(.badPath(change.path))
            }
        }

        var conflicts: [[String]] = []
        for path in changes.map(\.path) where !conflicts.contains(path) {
            if value(at: path, in: diskSpans.object) != value(at: path, in: baseSpans.object) { conflicts.append(path) }
        }
        if !conflicts.isEmpty { return .failure(.conflict(conflicts)) }

        var intended = diskSpans.object
        for change in changes { set(change.value, at: change.path, in: &intended) }
        let touched = Array(Set(changes.map { $0.path[0] })).sorted()
        for key in touched { normalize(key, in: &intended) }

        let decodedIntent: (config: PaddleConfig, issues: [ConfigIssue])
        do {
            decodedIntent = try PaddleConfig.decodeReportingIssues(Data(JSONValue.object(intended).render().utf8))
        } catch {
            return .failure(.invalidResult(PaddleConfig.describe(error)))
        }
        for change in changes {
            if let issue = blocker(for: change.path, in: decodedIntent.issues) { return .failure(.invalidResult(issue.id)) }
        }
        let intendedConfig = decodedIntent.config

        var spans = diskSpans
        for key in touched {
            let final = intended[key]
            guard final != spans.object[key] else { continue }
            let edited: Data
            if let final {
                let text = spans.text(for: final, key: key)
                edited = spans.member(key) != nil ? spans.replacing(key, with: text) : spans.appending(key, text: text)
            } else {
                edited = spans.removing(key)
            }
            do {
                spans = try JSONSpans.scan(edited)
            } catch {
                return .failure(.invalidResult(describe(error)))
            }
        }

        guard spans.object == intended else { return .failure(.invalidResult("edited file does not hold the intended values")) }
        do {
            // An untouched empty file stays empty; it reads as {} just as the scanner treats it.
            let decoded = try PaddleConfig.decode(spans.body == nil ? Data("{}".utf8) : spans.data)
            guard decoded == intendedConfig else { return .failure(.invalidResult("edited file decodes to a different config")) }
        } catch {
            return .failure(.invalidResult(PaddleConfig.describe(error)))
        }
        return .success(spans.data)
    }

    public struct TidyResult: Sendable, Equatable {
        /// Paths removed, in file order, so the user can be shown them before the data is written.
        public var removed: [[String]]
        public var data: Data
    }

    /// Drops every known key, `extensions` entry, `shortcuts` entry and `sites` field that holds its default. An
    /// explicit user action, so the result lists what went. `shortcutDefaults` is each action's default binding
    /// (an empty key for none); a `shortcuts` entry that parses to it is dropped, `"none"` on an action with no
    /// default included. A `sites` entry itself stays, even as `{}`: only its default-valued fields go.
    public static func tidy(_ data: Data, shortcutDefaults: [String: Shortcut] = [:]) -> Result<TidyResult, ConfigWriteError> {
        let spans: JSONSpans
        let issues: [ConfigIssue]
        do {
            spans = try JSONSpans.scan(data)
            issues = try PaddleConfig.decodeReportingIssues(data).issues
        } catch {
            return .failure(.invalidFile(describe(error)))
        }
        var changes: [ConfigChange] = []
        var seen: Set<String> = []
        for member in spans.members where seen.insert(member.key).inserted {
            let key = member.key
            guard let value = spans.object[key], let defaultValue = defaults[key] else { continue }
            if value == defaultValue {
                changes.append(ConfigChange(key, nil))
            } else if let entryDefault = entryDefault(in: key), let object = value.objectValue {
                for entry in spans.nestedKeys(of: key) ?? [] where object[entry] == entryDefault {
                    changes.append(ConfigChange(key, entry, nil))
                }
            } else if key == PaddleConfig.CodingKeys.shortcuts.rawValue, let object = value.objectValue {
                for entry in spans.nestedKeys(of: key) ?? [] {
                    guard case .string(let text)? = object[entry], let bound = Shortcut.parse(text),
                          let standard = shortcutDefaults[entry], bound.canonical == standard.canonical else { continue }
                    changes.append(ConfigChange(key, entry, nil))
                }
            } else if key == PaddleConfig.CodingKeys.sites.rawValue, let object = value.objectValue {
                for host in spans.nestedKeys(of: key) ?? [] {
                    guard let fields = object[host]?.objectValue else { continue }
                    for field in fields.keys.sorted() where fields[field] == siteFieldDefaults[field] {
                        changes.append(ConfigChange(path: [key, host, field], value: nil))
                    }
                }
            }
        }
        // Tidy leaves alone what Paddle skips or can't read (an entry with a wrong-typed field, say): those stay as written.
        changes = changes.filter { blocker(for: $0.path, in: issues) == nil }
        return apply(changes: changes, base: data, disk: data).map { TidyResult(removed: changes.map(\.path), data: $0) }
    }

    /// The first decode issue a change to `path` would land on: one at `path`, inside it, or on an entry `path` is inside.
    static func blocker(for path: [String], in issues: [ConfigIssue]) -> ConfigIssue? {
        issues.first { $0.path.starts(with: path) || path.starts(with: $0.path) }
    }

    /// Top-level keys `PaddleConfig` doesn't read, in file order: typos and leftovers from old versions.
    public static func unknownKeys(in data: Data) throws -> [String] {
        let known = Set(PaddleConfig.CodingKeys.allCases.map(\.rawValue))
        var unknown: [String] = []
        for member in try JSONSpans.scan(data).members where !known.contains(member.key) && !unknown.contains(member.key) {
            unknown.append(member.key)
        }
        return unknown
    }

    static func value(at path: [String], in object: [String: JSONValue]) -> JSONValue? {
        guard let first = path.first, var current = object[first] else { return nil }
        for part in path.dropFirst() {
            guard let next = current.objectValue?[part] else { return nil }
            current = next
        }
        return current
    }

    static func set(_ value: JSONValue?, at path: [String], in object: inout [String: JSONValue]) {
        if path.count == 1 {
            object[path[0]] = value
            return
        }
        var nested = object[path[0]]?.objectValue ?? [:]
        set(value, at: Array(path.dropFirst()), in: &nested)
        object[path[0]] = .object(nested)
    }

    /// Applies the default rules to one top-level key after its changes.
    static func normalize(_ key: String, in object: inout [String: JSONValue]) {
        guard var value = object[key] else { return }
        if let entryDefault = entryDefault(in: key), let entries = value.objectValue {
            value = .object(entries.filter { $0.value != entryDefault })
        }
        if value == defaults[key] || value.objectValue?.isEmpty == true {
            object[key] = nil
        } else {
            object[key] = value
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case JSONSpans.ScanError.invalidJSON(let text): return text
        case JSONSpans.ScanError.notAnObject: return "config.json must be a JSON object: { ... }"
        case JSONSpans.ScanError.notUTF8: return "config.json must be saved as UTF-8"
        default: return PaddleConfig.describe(error)
        }
    }
}
