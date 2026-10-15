import AppKit
import os
import PaddleCore
import SwiftUI
import WebKit

/// Site icons for tabs, bookmarks, suggestions and history: one 32 px PNG per site in favicons/, refetched
/// weekly when a page from that site finishes loading. WebKit loads and decodes the icon (size-capped, through its
/// own networking, in its sandboxed web process), so Paddle never parses page-chosen image bytes itself.
@Observable
final class FaviconStore {
    /// Loaded icons by site key. Observed, so views redraw when an icon arrives.
    private var images: [String: NSImage] = [:]
    /// Mean relative luminance (0-1) of each loaded icon's visible pixels, measured once when it loads.
    @ObservationIgnored private var luminance: [String: Double] = [:]
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var pendingDiskLoads: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    private let log = Logger(subsystem: "com.walker.Paddle", category: "favicons")

    private static let maxBytes = 512 * 1024
    private static let pixels: CGFloat = 32
    private static let loadSelector = NSSelectorFromString("_loadAndDecodeImage:constrainedToSize:maximumBytesFromNetwork:completionHandler:")

    /// The page's icon links, its address, the hosts it loaded resources from and its user agent.
    private struct PageIcons: Decodable {
        var icons: [IconCandidate]
        var href: String
        var hosts: [String]
        var userAgent: String
    }

    private static let pageScript = """
        return JSON.stringify({
            icons: JSON.parse(\(FaviconPicker.collectScript)),
            href: location.href,
            hosts: Array.from(new Set(performance.getEntriesByType('resource').map(function (entry) {
                try { return new URL(entry.name).hostname; } catch (e) { return ''; }
            }))),
            userAgent: navigator.userAgent
        })
        """

    /// The icon for `url`'s site if Paddle has one. A miss starts a disk load (never a network fetch) and the
    /// view redraws when it lands, so this is safe to call while drawing.
    func image(for url: URL?) -> NSImage? {
        guard let url, let key = FaviconPicker.cacheKey(for: url) else { return nil }
        if let image = images[key] { return image }
        if !missing.contains(key), pendingDiskLoads.insert(key).inserted {
            DispatchQueue.main.async { [weak self] in self?.loadFromDisk(key) }
        }
        return nil
    }

    /// Mean relative luminance (WCAG: 0 black to 1 white) of the visible pixels of `url`'s site icon; nil without an
    /// icon. Lets a view put a near-black icon on a light plate in dark mode, and a near-white one on a dark plate.
    func luminance(for url: URL?) -> Double? {
        guard let url, let key = FaviconPicker.cacheKey(for: url) else { return nil }
        return luminance[key]
    }

    /// For menus, which don't redraw when an icon arrives: a miss reads the disk right away.
    func cachedImage(for url: URL) -> NSImage? {
        guard let key = FaviconPicker.cacheKey(for: url) else { return nil }
        if images[key] == nil, !missing.contains(key) { loadFromDisk(key) }
        return images[key]
    }

    /// Called when a page finishes loading: fetches its site's icon unless a fresh one is on disk. With history
    /// off, icons are kept on disk only for sites you have bookmarked.
    func refresh(for webView: WKWebView) async {
        guard let url = webView.url, HistoryStore.isRecordable(url), webView.responds(to: Self.loadSelector) else { return }
        // Most loads are on a site whose icon is fresh or already being fetched: settle that from the address
        // before running a script in the page. The document's own address below still decides where an icon goes.
        if let key = FaviconPicker.cacheKey(for: url) {
            if images[key] == nil, !missing.contains(key) { loadFromDisk(key) }
            if let date = fetchedAt[key], !FaviconPicker.isStale(fetchedAt: date, now: Date()) { return }
            if inFlight.contains(key) { return }
        }
        // Read from an isolated script world, out of the page's reach. The address comes from the document
        // itself, so a navigation starting meanwhile can't file this icon under another site.
        guard let raw = try? await webView.callAsyncJavaScript(Self.pageScript, contentWorld: .defaultClient) as? String,
              let page = try? JSONDecoder().decode(PageIcons.self, from: Data(raw.utf8)),
              let pageURL = URL(string: page.href), HistoryStore.isRecordable(pageURL),
              let key = FaviconPicker.cacheKey(for: pageURL) else { return }
        if images[key] == nil { loadFromDisk(key) }
        if let date = fetchedAt[key], !FaviconPicker.isStale(fetchedAt: date, now: Date()) { return }
        guard inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }

        // Only from hosts the page already loaded from (so the content blockers allowed them), else the site's
        // own /favicon.ico, which is also the fallback when the chosen icon fails.
        let allowed = Set((page.hosts + [pageURL.host() ?? ""]).map { $0.lowercased() })
        var choices: [URL] = []
        if let best = FaviconPicker.bestIcon(page.icons, pageURL: pageURL),
           best.scheme == "data" || allowed.contains(best.host()?.lowercased() ?? "") {
            choices.append(best)
        }
        if let fallback = FaviconPicker.bestIcon([], pageURL: pageURL), !choices.contains(fallback) {
            choices.append(fallback)
        }
        var icon: NSImage?
        for choice in choices where icon == nil {
            icon = await Self.load(choice, userAgent: page.userAgent, in: webView)
        }
        fetchedAt[key] = Date()   // found or not, try again next week, not on every load
        guard let icon, let png = Self.png(icon), let image = Self.image(png) else {
            log.info("no usable icon for \(key, privacy: .public)")
            return
        }
        keep(image, for: key)
        missing.remove(key)
        guard AppModel.shared.history != nil || AppModel.shared.bookmarks.siteKeys.contains(key) else { return }
        do {
            try FileManager.default.createDirectory(at: Paths.favicons, withIntermediateDirectories: true)
            try png.write(to: Paths.favicons.appending(path: FaviconPicker.fileName(forKey: key)), options: .atomic)
        } catch {
            log.error("icon write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// History > Clear History: drops icons fetched since `date` (all when nil), except for sites in `keeping`.
    func forget(since date: Date?, keeping keys: Set<String>) {
        let kept = Set(keys.map(FaviconPicker.fileName(forKey:)))
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.favicons, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !kept.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if date.map({ modified >= $0 }) ?? true { try? FileManager.default.removeItem(at: file) }
        }
        images = images.filter { keys.contains($0.key) }
        luminance = luminance.filter { keys.contains($0.key) }
        fetchedAt = fetchedAt.filter { keys.contains($0.key) }
        missing.removeAll()
    }

    private func keep(_ image: NSImage, for key: String) {
        luminance[key] = Self.meanLuminance(image)
        images[key] = image
    }

    /// The icon drawn at 16 x 16; the mean of its pixels' relative luminance (linearized sRGB), weighted by opacity.
    private static func meanLuminance(_ image: NSImage) -> Double? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0, weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.1 else { continue }
            // Premultiplied: divide by alpha for the color, then weight the pixel's luminance by alpha.
            func linear(_ byte: UInt8) -> Double {
                let value = min(1, Double(byte) / 255 / alpha)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let red = linear(pixels[index]), green = linear(pixels[index + 1]), blue = linear(pixels[index + 2])
            total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
            weight += alpha
        }
        return weight > 0 ? total / weight : nil
    }

    private func loadFromDisk(_ key: String) {
        pendingDiskLoads.remove(key)
        let file = Paths.favicons.appending(path: FaviconPicker.fileName(forKey: key))
        guard let data = try? Data(contentsOf: file), let image = Self.image(data) else {
            missing.insert(key)
            return
        }
        keep(image, for: key)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        fetchedAt[key] = modified
    }

    /// A stored 32 px icon, sized 16 pt so it is crisp on 2x screens (menus use the size as is).
    private static func image(_ png: Data) -> NSImage? {
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// WebKit's image loader (private API, guarded by the caller): loads with the page's networking and cookies,
    /// gives up past `maxBytes` and decodes in the web content process. It would send WebKit's networking user
    /// agent, so the page's is set instead.
    private static func load(_ url: URL, userAgent: String, in webView: WKWebView) async -> NSImage? {
        typealias Load = @convention(c) (WKWebView, Selector, NSURLRequest, CGSize, Int, @escaping @convention(block) (NSImage?, NSError?) -> Void) -> Void
        let load = unsafeBitCast(webView.method(for: loadSelector), to: Load.self)
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { continuation in
            load(webView, loadSelector, request as NSURLRequest, CGSize(width: pixels, height: pixels), maxBytes) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Redraws the icon at 32 px and encodes it as PNG.
    private static func png(_ image: NSImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// A site's icon, or an SF Symbol until Paddle has one.
struct FaviconView: View {
    let url: URL?
    var fallback = "globe"
    var size: CGFloat = 14
    var fallbackStyle = AnyShapeStyle(.secondary)

    var body: some View {
        if let image = AppModel.shared.favicons.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8))
                .foregroundStyle(fallbackStyle)
                .frame(width: size, height: size)
        }
    }
}
