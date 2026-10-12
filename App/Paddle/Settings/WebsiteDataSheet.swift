import PaddleCore
import SwiftUI
import WebKit

/// Settings > Privacy & Blocking > Manage Website Data…: what each site has stored in Paddle's (non-private) data
/// store, with its size where WebKit reports one, and Remove / Remove All. The list is fetched when the sheet
/// opens and dropped when it closes. Extension storage (`webkit-extension://`, `chrome-extension://` and `moz-extension://` origins) is listed apart and left
/// out of Remove All, so clearing sites never signs an extension out.
struct WebsiteDataSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sites: [WebsiteDataSite]?
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var confirmingRemoveAll = false
    @State private var confirmingRemoveSelected = false
    @State private var isRemoving = false

    private var store: WKWebsiteDataStore { AppModel.shared.web.dataStore }

    private var shown: [WebsiteDataSite] {
        let all = sites ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? all : all.filter { $0.title.lowercased().contains(query) }
    }

    private var removableAll: [WebsiteDataSite] { (sites ?? []).filter { !$0.isExtension } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Website Data").font(.headline)
            Text("Cookies, caches and storage sites keep in Paddle. Removing a site's data signs you out of it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $search, prompt: Text("Search sites"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search sites")

            Group {
                if let sites {
                    if sites.isEmpty {
                        ContentUnavailableView("No website data", systemImage: "tray")
                    } else {
                        Table(shown, selection: $selection) {
                            TableColumn("Site", value: \.title)
                            TableColumn("Stored") { site in
                                Text(site.kinds).foregroundStyle(.secondary)
                            }
                            TableColumn("Size") { site in
                                let size = site.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                                Text(size ?? "–")
                                    .monospacedDigit()
                                    .accessibilityLabel(size ?? "Size unknown")
                            }
                            .width(min: 60, ideal: 80, max: 100)
                        }
                    }
                } else {
                    ProgressView("Loading website data…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)

            HStack {
                Button("Remove…") { confirmingRemoveSelected = true }
                    .disabled(selection.isEmpty || isRemoving)
                    .help("Removes everything the selected sites stored.")
                Button("Remove All…") { confirmingRemoveAll = true }
                    .disabled(removableAll.isEmpty || isRemoving)
                    .help("Removes every site's data. Extensions' own storage stays.")
                if isRemoving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog(
            "Remove data stored by \(removableAll.count) \(removableAll.count == 1 ? "site" : "sites")?",
            isPresented: $confirmingRemoveAll
        ) {
            Button("Remove All", role: .destructive) { Task { await remove(removableAll) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out of these sites, and their caches and storage are deleted. This can't be undone.")
        }
        .confirmationDialog(
            "Remove data stored by \(selectedSites.count) \(selectedSites.count == 1 ? "site" : "sites")?",
            isPresented: $confirmingRemoveSelected
        ) {
            Button("Remove", role: .destructive) { Task { await remove(selectedSites) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out of \(selectedSites.map(\.title).formatted()), and their caches and storage are deleted. This can't be undone.")
        }
    }

    private var selectedSites: [WebsiteDataSite] { shown.filter { selection.contains($0.id) } }

    private func load() async {
        sites = await WebsiteDataSite.fetch(from: store)
        selection.formIntersection(Set(sites?.map(\.id) ?? []))
    }

    private func remove(_ sites: [WebsiteDataSite]) async {
        guard !sites.isEmpty else { return }
        isRemoving = true
        let types = sites.reduce(into: Set<String>()) { $0.formUnion($1.record.dataTypes) }
        await store.removeData(ofTypes: types, for: sites.map(\.record))
        isRemoving = false
        let count = sites.count
        AccessibilityNotification.Announcement("Removed data for \(count) \(count == 1 ? "site" : "sites")").post()
        await load()
    }
}

/// One site's record: WebKit groups records by registrable domain (its `displayName`).
struct WebsiteDataSite: Identifiable {
    let record: WKWebsiteDataRecord
    let title: String
    let kinds: String
    /// Bytes on disk, when the private size API is there; nil otherwise.
    let size: UInt64?
    let isExtension: Bool

    var id: String { record.displayName }

    /// Every record in `store`, with sizes through WebKit's private `_fetchDataRecordsOfTypes:withOptions:` (option
    /// 1 computes sizes) when it exists, else the public fetch without them. Sorted largest first, then by name.
    static func fetch(from store: WKWebsiteDataStore) async -> [WebsiteDataSite] {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord]
        if store.responds(to: fetchWithSizes) {
            typealias Fetch = @convention(c) (WKWebsiteDataStore, Selector, NSSet, UInt, @escaping @convention(block) (NSArray) -> Void) -> Void
            let fetch = unsafeBitCast(store.method(for: fetchWithSizes), to: Fetch.self)
            records = await withCheckedContinuation { continuation in
                fetch(store, fetchWithSizes, types as NSSet, 1) { array in
                    continuation.resume(returning: array.compactMap { $0 as? WKWebsiteDataRecord })
                }
            }
        } else {
            records = await store.dataRecords(ofTypes: types)
        }

        let extensionNames = Dictionary(
            AppModel.shared.extensions.loaded.flatMap { [($0.id, $0.name), ($0.urlHost, $0.name)] }, uniquingKeysWith: { first, _ in first }
        )
        return records.map { record in
            let isExtension = extensionNames[record.displayName] != nil || isExtensionIdentifier(record.displayName)
            let title = isExtension
                ? "Extension: \(extensionNames[record.displayName] ?? "not loaded (\(record.displayName.prefix(8))…)")"
                : record.displayName
            return WebsiteDataSite(record: record, title: title, kinds: kinds(record.dataTypes), size: size(of: record), isExtension: isExtension)
        }
        .sorted { ($0.size ?? 0, $1.title) > ($1.size ?? 0, $0.title) }
    }

    private static let fetchWithSizes = NSSelectorFromString("_fetchDataRecordsOfTypes:withOptions:completionHandler:")
    private static let dataSizeKey = "_dataSize"

    /// `record._dataSize.totalSize`, guarded: nil when either private piece is missing or sizes weren't computed.
    private static func size(of record: WKWebsiteDataRecord) -> UInt64? {
        guard record.responds(to: NSSelectorFromString(dataSizeKey)),
              let size = record.value(forKey: dataSizeKey) as? NSObject,
              size.responds(to: NSSelectorFromString("totalSize")),
              let total = size.value(forKey: "totalSize") as? NSNumber else { return nil }
        return total.uint64Value
    }

    /// Extension ids and page hosts: 32 lowercase hex characters, Chrome's 32 letters a–p, or Firefox's UUID
    /// (`ExtensionIdentity.looksLikeExtensionHost`); no web domain looks like those.
    private static func isExtensionIdentifier(_ name: String) -> Bool {
        ExtensionIdentity.looksLikeExtensionHost(name)
    }

    /// "Cookies, Cache, Local storage" from WebKit's type names.
    private static func kinds(_ types: Set<String>) -> String {
        var names: [String] = []
        func add(_ name: String) { if !names.contains(name) { names.append(name) } }
        for type in types.sorted() {
            switch type {
            case WKWebsiteDataTypeCookies: add("Cookies")
            case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache: add("Cache")
            case WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage: add("Local storage")
            case WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases: add("Databases")
            case WKWebsiteDataTypeServiceWorkerRegistrations: add("Service workers")
            case WKWebsiteDataTypeFileSystem: add("Files")
            case WKWebsiteDataTypeMediaKeys: add("Media keys")
            default: add("Other")
            }
        }
        return names.sorted { ($0 == "Other" ? 1 : 0, $0) < ($1 == "Other" ? 1 : 0, $1) }.joined(separator: ", ")
    }
}
