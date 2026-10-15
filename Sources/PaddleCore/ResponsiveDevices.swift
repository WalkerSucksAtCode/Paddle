import Foundation

/// A device size for Responsive Design Mode, in points.
public struct ResponsiveDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    /// The user agent the preset starts with.
    public let userAgent: ResponsiveUserAgent

    public init(id: String, name: String, width: Int, height: Int, userAgent: ResponsiveUserAgent) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.userAgent = userAgent
    }

    /// The size with width and height swapped, for landscape.
    public func rotated() -> (width: Int, height: Int) { (height, width) }

    /// "iPhone 16 — 393 × 852": the name and the size, for pickers.
    public var label: String { "\(name) — \(width) × \(height)" }

    public static let presets: [ResponsiveDevice] = [
        ResponsiveDevice(id: "iphone-se", name: "iPhone SE", width: 375, height: 667, userAgent: .safariIPhone),
        ResponsiveDevice(id: "iphone-16", name: "iPhone 16", width: 393, height: 852, userAgent: .safariIPhone),
        ResponsiveDevice(id: "iphone-16-pro-max", name: "iPhone 16 Pro Max", width: 440, height: 956, userAgent: .safariIPhone),
        ResponsiveDevice(id: "ipad-mini", name: "iPad mini", width: 744, height: 1133, userAgent: .safariIPad),
        ResponsiveDevice(id: "ipad-air", name: "iPad Air", width: 820, height: 1180, userAgent: .safariIPad),
        ResponsiveDevice(id: "laptop", name: "Laptop", width: 1280, height: 800, userAgent: .paddle),
    ]

    public static func preset(id: String) -> ResponsiveDevice? { presets.first { $0.id == id } }
}

/// The user agent Responsive Design Mode sends.
public enum ResponsiveUserAgent: String, CaseIterable, Sendable {
    case paddle, safariIPhone, safariIPad, chromeAndroid

    public var displayName: String {
        switch self {
        case .paddle: "Paddle"
        case .safariIPhone: "Safari iPhone"
        case .safariIPad: "Safari iPad"
        case .chromeAndroid: "Chrome Android"
        }
    }

    /// The user agent string; nil for Paddle, meaning the tab's normal one.
    public var string: String? {
        switch self {
        case .paddle: nil
        case .safariIPhone:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .safariIPad:
            "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        case .chromeAndroid:
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"
        }
    }
}

/// One tab's Responsive Design Mode settings.
public struct ResponsiveState: Sendable, Equatable {
    public var deviceID: String
    public var rotated: Bool
    public var userAgent: ResponsiveUserAgent

    public init(device: ResponsiveDevice = ResponsiveDevice.presets[1]) {
        deviceID = device.id
        rotated = false
        userAgent = device.userAgent
    }

    public var device: ResponsiveDevice { ResponsiveDevice.preset(id: deviceID) ?? ResponsiveDevice.presets[1] }

    /// The page size in points, rotation applied.
    public var size: (width: Int, height: Int) { rotated ? device.rotated() : (device.width, device.height) }
}
