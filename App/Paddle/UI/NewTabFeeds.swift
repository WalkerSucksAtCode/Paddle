import AppKit
import Foundation
import ImageIO
import os
import PaddleCore

/// The New Tab page's News section: the newest stories of `newTabFeeds`, fetched by Paddle itself (no web view, no
/// cookies) when a New Tab shows and the last fetch is over `refreshInterval` old, and cached in `feeds-cache.json`
/// so they show at once after a launch.
@Observable
final class FeedStore {
    static let shared = FeedStore()

    /// Stories from every feed, newest first, at most `maxItems`.
    private(set) var items: [FeedItem] = []
    /// Feed address → why its last fetch failed; a feed that worked has no entry.
    private(set) var problems: [String: String] = [:]
    private(set) var refreshing = false

    static let refreshInterval: TimeInterval = 30 * 60
    static let maxItems = 24
    private static let maxBytes = 2 * 1024 * 1024
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "feeds")

    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastFeeds: [String] = []
    @ObservationIgnored private var loadedCache = false

    /// No cookies, no cache, no credentials: a feed fetch sends nothing about you but the request itself.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private struct Cache: Codable {
        var feeds: [String]
        var fetched: Date
        var items: [FeedItem]
    }

    /// Called when a New Tab shows: the cache first (once), then a fetch when the feeds changed or the stories are old.
    func refreshIfDue(feeds: [String]) {
        if !loadedCache { loadCache(feeds: feeds) }
        guard !feeds.isEmpty else {
            items = []
            problems = [:]
            return
        }
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        guard !refreshing, stale || feeds != lastFeeds else { return }
        Task { await refresh(feeds: feeds) }
    }

    func refresh(feeds: [String]) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var all: [FeedItem] = []
        var failed: [String: String] = [:]
        await withTaskGroup(of: (String, Result<[FeedItem], FeedError>).self) { group in
            for feed in feeds {
                group.addTask { (feed, await Self.fetch(feed)) }
            }
            for await (feed, result) in group {
                switch result {
                case .success(let found): all += found.prefix(10)
                case .failure(let error): failed[feed] = error.message
                }
            }
        }
        items = Array(FeedParser.sortedNewestFirst(all).prefix(Self.maxItems))
        problems = failed
        lastRefresh = Date()
        lastFeeds = feeds
        saveCache()
        Self.log.info("feeds: \(all.count, privacy: .public) stories from \(feeds.count - failed.count, privacy: .public) of \(feeds.count, privacy: .public) feeds")
    }

    struct FeedError: Error {
        let message: String
    }

    /// The feed address an address typed in Settings stands for: the address itself when it is a feed, else the feed
    /// the page links to (`<link rel="alternate">`). "example.com" is read as https://example.com.
    static func resolve(_ typed: String) async -> Result<URL, FeedError> {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
            return .failure(FeedError(message: "That isn't a web address."))
        }
        switch await download(url) {
        case .failure(let error): return .failure(error)
        case .success(let (data, final)):
            if FeedParser.parse(data, base: final) != nil { return .success(final) }
            let html = String(decoding: data, as: UTF8.self)
            guard let linked = FeedParser.discover(html: html, base: final) else {
                return .failure(FeedError(message: "No RSS or Atom feed found there."))
            }
            switch await download(linked) {
            case .success(let (feedData, feedURL)) where FeedParser.parse(feedData, base: feedURL) != nil:
                return .success(feedURL)
            default:
                return .failure(FeedError(message: "The page links a feed that couldn't be read."))
            }
        }
    }

    private static func fetch(_ address: String) async -> Result<[FeedItem], FeedError> {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .failure(FeedError(message: "Not an http(s) address."))
        }
        switch await download(url) {
        case .failure(let error): return .failure(error)
        case .success(let (data, final)):
            guard let feed = FeedParser.parse(data, base: final) else {
                return .failure(FeedError(message: "Not an RSS or Atom feed."))
            }
            return .success(feed.items)
        }
    }

    private static func download(_ url: URL) async -> Result<(Data, URL), FeedError> {
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(FeedError(message: "No answer.")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(FeedError(message: "The site answered \(http.statusCode)."))
            }
            guard data.count <= maxBytes else { return .failure(FeedError(message: "The feed is over 2 MB.")) }
            return .success((data, response.url ?? url))
        } catch {
            return .failure(FeedError(message: error.localizedDescription))
        }
    }

    // MARK: - Pictures

    @ObservationIgnored private let images = NSCache<NSURL, NSImage>()
    private static let maxImageBytes = 3 * 1024 * 1024

    /// A story's picture, fetched like the feeds (no cookies), at most 3 MB, scaled down to `maxPixel` on its longer
    /// side and kept in memory for this run. Nil when it can't be had.
    func image(for url: URL, maxPixel: CGFloat) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    private func loadCache(feeds: [String]) {
        loadedCache = true
        guard let data = try? Data(contentsOf: Paths.feedsCache),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.feeds == feeds else { return }
        items = cache.items
        lastRefresh = cache.fetched
        lastFeeds = cache.feeds
    }

    private func saveCache() {
        let cache = Cache(feeds: lastFeeds, fetched: lastRefresh ?? Date(), items: items)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Paths.feedsCache, options: .atomic)
    }
}

/// The website notifications of this run, newest first, for New Tab's Notifications section (`newTabNotifications`).
/// Kept in memory only, never written to disk; private windows' notifications never reach it.
@Observable
final class NotificationInbox {
    static let shared = NotificationInbox()
    static let maxEntries = 30

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let origin: String
        let host: String
        let title: String
        let body: String
        let date: Date
        /// The profile whose page sent it: only that profile's New Tab lists it.
        let profile: String
    }

    private(set) var entries: [Entry] = []

    func record(origin: String, host: String, title: String, body: String, profile: String) {
        guard !host.isEmpty, !(title.isEmpty && body.isEmpty) else { return }
        entries.insert(Entry(origin: origin, host: host, title: title, body: body, date: Date(), profile: profile), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// Clears one profile's entries; the others' New Tab pages keep theirs.
    func clear(profile: String) { entries.removeAll { $0.profile == profile } }

    func remove(_ entry: Entry) { entries.removeAll { $0.id == entry.id } }
}
