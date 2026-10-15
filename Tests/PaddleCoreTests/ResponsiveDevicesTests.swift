import Foundation
@testable import PaddleCore
import Testing

struct ResponsiveDevicesTests {
    @Test func presetsAndSizes() {
        let p = ResponsiveDevice.presets
        #expect(p.map(\.name) == ["iPhone SE", "iPhone 16", "iPhone 16 Pro Max", "iPad mini", "iPad Air", "Laptop"])
        #expect(p.map { "\($0.width)x\($0.height)" } == ["375x667", "393x852", "440x956", "744x1133", "820x1180", "1280x800"])
        #expect(Set(p.map(\.id)).count == p.count)
        #expect(p[1].label == "iPhone 16 — 393 × 852")
    }

    @Test func rotation() {
        let r = ResponsiveDevice.presets[1].rotated()
        #expect(r.width == 852 && r.height == 393)
        var state = ResponsiveState(device: ResponsiveDevice.presets[1])
        #expect(state.size.width == 393)
        state.rotated = true
        #expect(state.size.width == 852)
    }

    @Test func userAgents() {
        let strings = ResponsiveUserAgent.allCases.compactMap(\.string)
        #expect(strings.count == 3)
        #expect(Set(strings).count == 3)
        #expect(strings.allSatisfy { !$0.isEmpty })
        #expect(ResponsiveUserAgent.paddle.string == nil)
        #expect(ResponsiveState(device: ResponsiveDevice.presets[0]).userAgent == .safariIPhone)
    }
}
