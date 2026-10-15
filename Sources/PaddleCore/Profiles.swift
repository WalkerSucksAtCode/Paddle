import Foundation

/// The symbols a profile can wear, shown beside its name so profiles are never told apart by color alone.
public enum ProfileSymbol: String, CaseIterable, Codable, Sendable {
    case person, work, home, school, tools, games, shopping, health, star, leaf

    public var displayName: String {
        switch self {
        case .person: "Person"
        case .work: "Work"
        case .home: "Home"
        case .school: "School"
        case .tools: "Tools"
        case .games: "Games"
        case .shopping: "Shopping"
        case .health: "Health"
        case .star: "Star"
        case .leaf: "Leaf"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .person: "person"
        case .work: "briefcase"
        case .home: "house"
        case .school: "graduationcap"
        case .tools: "hammer"
        case .games: "gamecontroller"
        case .shopping: "cart"
        case .health: "heart"
        case .star: "star"
        case .leaf: "leaf"
        }
    }
}

/// One browsing profile: its own cookies, logins, storage, cache and history.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    /// `ProfilesFile.defaultID` for the default profile, else a UUID string (it names the WebKit data store).
    public var id: String
    public var name: String
    public var symbol: ProfileSymbol
    /// Extension folder name -> on. Another profile starts with none; the default profile ignores this and uses
    /// config.json's `extensions`.
    public var extensions: [String: Bool]

    public init(id: String, name: String, symbol: ProfileSymbol = .person, extensions: [String: Bool] = [:]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.extensions = extensions
    }

    public var isDefault: Bool { id == ProfilesFile.defaultID }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, extensions }

    /// Lenient, for hand-edited files: `id` is required; an unknown or missing symbol is Person, a missing name
    /// stays empty (the file drops it unless it is the default profile), bad extension flags are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        symbol = (try? c.decodeIfPresent(ProfileSymbol.self, forKey: .symbol)) ?? .person
        var flags: [String: Bool] = [:]
        if let raw = try? c.decodeIfPresent([String: Lossy<Bool>].self, forKey: .extensions) {
            for (folder, flag) in raw { if let value = flag.value { flags[folder] = value } }
        }
        extensions = flags
    }
}

private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// profiles.json: the profiles, the default one always first.
public struct ProfilesFile: Codable, Sendable, Equatable {
    public static let defaultID = "default"
    public static let defaultName = "Personal"

    public private(set) var profiles: [Profile]

    public init(profiles: [Profile] = []) {
        self.profiles = Self.normalized(profiles)
    }

    private enum CodingKeys: String, CodingKey { case profiles }

    /// Lenient: bad entries, duplicate ids, nameless profiles and ids that aren't UUIDs (WebKit can't name a store
    /// with them) are skipped; unknown keys are ignored. The default profile is always there, first.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([Lossy<Profile>].self, forKey: .profiles)
        profiles = Self.normalized((decoded ?? []).compactMap(\.value))
    }

    private static func normalized(_ input: [Profile]) -> [Profile] {
        var seen: Set<String> = []
        var others: [Profile] = []
        var first: Profile?
        for var profile in input {
            guard seen.insert(profile.id).inserted else { continue }
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if profile.id == defaultID {
                if profile.name.isEmpty { profile.name = defaultName }
                first = profile
            } else if UUID(uuidString: profile.id) != nil, !profile.name.isEmpty {
                others.append(profile)
            }
        }
        return [first ?? Profile(id: defaultID, name: defaultName, symbol: .person)] + others
    }

    public static func decode(_ data: Data) throws -> ProfilesFile {
        try JSONDecoder().decode(ProfilesFile.self, from: data)
    }

    /// Pretty, with sorted keys, so the file diffs and hand-edits well.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func profile(id: String) -> Profile? { profiles.first { $0.id == id } }

    /// A new profile with a fresh UUID id. An empty name becomes "Profile".
    @discardableResult
    public mutating func add(name: String, symbol: ProfileSymbol) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Profile" : trimmed
        // Names stay unique, so menus and badges tell profiles apart by name: "New Profile 2", "New Profile 3"…
        var unique = base
        var number = 2
        while isNameTaken(unique, except: nil) {
            unique = "\(base) \(number)"
            number += 1
        }
        let profile = Profile(id: UUID().uuidString, name: unique, symbol: symbol)
        profiles.append(profile)
        return profile
    }

    /// False when `id` is unknown, `name` is empty, or another profile has that name (case aside).
    @discardableResult
    public mutating func rename(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNameTaken(trimmed, except: id), let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].name = trimmed
        return true
    }

    /// Whether a profile other than `except` is called `name`, ignoring case.
    func isNameTaken(_ name: String, except id: String?) -> Bool {
        profiles.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    public mutating func setSymbol(_ symbol: ProfileSymbol, for id: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].symbol = symbol
        return true
    }

    /// Removes a profile. The default profile can't be removed.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard id != Self.defaultID, let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles.remove(at: index)
        return true
    }

    /// Turns the extension in `folder` on or off for a non-default profile. False for the default profile (it uses
    /// config.json) and unknown ids.
    @discardableResult
    public mutating func setExtension(folder: String, on: Bool, for id: String) -> Bool {
        guard id != Self.defaultID, let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].extensions[folder] = on
        return true
    }
}
