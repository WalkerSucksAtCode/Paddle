import Foundation

/// Chromium's session files (`Sessions/Session_<n>`, `Current Session`): a command log in the "SNSS" format that
/// Chrome replays at launch. Only the commands that decide which tabs are open are read; everything else, and
/// anything too short to be what it claims, is skipped.
enum SNSS {
    /// One tab's current page.
    struct Tab: Equatable {
        var url: String
        var title: String
        var pinned: Bool
    }

    /// A normal window's tabs in tab-strip order; `selected` indexes `tabs` (0 when the file doesn't say).
    struct Window: Equatable {
        var tabs: [Tab]
        var selected: Int
    }

    static let supportedVersion: Int32 = 3

    private struct TabState {
        var window: Int32?
        var indexInWindow: Int32?
        var pinned = false
        var selectedNav: Int32?
        var navs: [Int32: (url: String, title: String)] = [:]
    }

    private struct WindowState {
        var type: Int32?
        var selectedTabIndex: Int32?
    }

    static func decode(_ data: Data) throws -> [Window] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, int32(bytes, 0) == 0x5353_4E53 else {
            throw BrowserImportError.unreadable("Paddle can't read this session file.")
        }
        let version = int32(bytes, 4)
        guard version == supportedVersion else {
            throw BrowserImportError.unreadable(
                "This session file uses a format Paddle can't read (version \(version)); newer Chrome versions encrypt it.")
        }

        var tabs: [Int32: TabState] = [:]
        var windows: [Int32: WindowState] = [:]
        var position = 8
        while position + 2 <= bytes.count {
            let size = Int(bytes[position]) | Int(bytes[position + 1]) << 8
            if size == 0 || position + 2 + size > bytes.count { break }
            let id = bytes[position + 2]
            let payload = Array(bytes[(position + 3)..<(position + 2 + size)])
            position += 2 + size

            func ints(_ count: Int) -> [Int32]? {
                guard payload.count >= count * 4 else { return nil }
                return (0..<count).map { int32(payload, $0 * 4) }
            }
            switch id {
            case 0:  // SetTabWindow: window, tab
                guard let v = ints(2) else { continue }
                tabs[v[1], default: TabState()].window = v[0]
                windows[v[0], default: WindowState()] = windows[v[0]] ?? WindowState()
            case 2:  // SetTabIndexInWindow
                guard let v = ints(2) else { continue }
                tabs[v[0], default: TabState()].indexInWindow = v[1]
            case 6:  // UpdateTabNavigation
                guard let (tab, index, url, title) = navigation(payload) else { continue }
                tabs[tab, default: TabState()].navs[index] = (url, title)
            case 7:  // SetSelectedNavigationIndex
                guard let v = ints(2) else { continue }
                tabs[v[0], default: TabState()].selectedNav = v[1]
            case 8:  // SetSelectedTabInIndex
                guard let v = ints(2) else { continue }
                windows[v[0], default: WindowState()].selectedTabIndex = v[1]
            case 9:  // SetWindowType
                guard let v = ints(2) else { continue }
                windows[v[0], default: WindowState()].type = v[1]
            case 12:  // SetPinnedState: tab, bool
                guard payload.count >= 5 else { continue }
                tabs[int32(payload, 0), default: TabState()].pinned = payload[4] != 0
            case 16:  // TabClosed
                guard let v = ints(1) else { continue }
                tabs[v[0]] = nil
            case 17:  // WindowClosed
                guard let v = ints(1) else { continue }
                windows[v[0]] = nil
                tabs = tabs.filter { $0.value.window != v[0] }
            case 24:  // TabNavigationPathPruned: tab, first removed, count
                guard let v = ints(3), v[2] > 0, var tab = tabs[v[0]] else { continue }
                var kept: [Int32: (url: String, title: String)] = [:]
                for (index, entry) in tab.navs {
                    if index < v[1] {
                        kept[index] = entry
                    } else if index >= v[1] + v[2] {
                        kept[index - v[2]] = entry
                    }
                }
                tab.navs = kept
                tabs[v[0]] = tab
            default:
                continue
            }
        }

        var result: [Window] = []
        for windowID in windows.keys.sorted() {
            guard let window = windows[windowID], window.type == nil || window.type == 0 else { continue }
            let members = tabs.filter { $0.value.window == windowID && !$0.value.navs.isEmpty }
                .sorted { lhs, rhs in
                    let l = lhs.value.indexInWindow ?? .max
                    let r = rhs.value.indexInWindow ?? .max
                    return l != r ? l < r : lhs.key < rhs.key
                }
            guard !members.isEmpty else { continue }
            let list = members.map { _, state -> Tab in
                let entry = state.selectedNav.flatMap { state.navs[$0] }
                    ?? state.navs[state.navs.keys.max()!]!
                return Tab(url: entry.url, title: entry.title, pinned: state.pinned)
            }
            let selected = window.selectedTabIndex.flatMap { wanted in
                members.firstIndex { $0.value.indexInWindow == wanted }
            } ?? 0
            result.append(Window(tabs: list, selected: selected))
        }
        return result
    }

    // MARK: - Parsing

    private static func int32(_ bytes: [UInt8], _ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
    }

    /// A pickled navigation: payload size, tab id, index, the URL, then the title; parsing stops there.
    private static func navigation(_ payload: [UInt8]) -> (Int32, Int32, String, String)? {
        guard payload.count >= 16 else { return nil }
        let tab = int32(payload, 4)
        let index = int32(payload, 8)
        let urlLength = Int(int32(payload, 12))
        guard urlLength >= 0, urlLength <= payload.count - 16 else { return nil }
        let url = String(decoding: payload[16..<(16 + urlLength)], as: UTF8.self)
        let titleAt = 16 + ((urlLength + 3) & ~3)
        var title = ""
        if titleAt + 4 <= payload.count {
            let chars = Int(int32(payload, titleAt))
            if chars > 0, chars <= (payload.count - titleAt - 4) / 2 {
                let units = (0..<chars).map { i -> UInt16 in
                    UInt16(payload[titleAt + 4 + 2 * i]) | UInt16(payload[titleAt + 5 + 2 * i]) << 8
                }
                title = String(decoding: units, as: UTF16.self)
            }
        }
        return (tab, index, url, title)
    }
}
