import Foundation
@testable import PaddleCore
import Testing

struct ExtensionUpdatePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    @Test func neverCheckedIsDue() {
        #expect(ExtensionUpdatePolicy.shouldCheck(lastCheck: nil, now: now, enabled: true))
    }

    @Test func offMeansNeverDue() {
        #expect(!ExtensionUpdatePolicy.shouldCheck(lastCheck: nil, now: now, enabled: false))
        #expect(!ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(48), now: now, enabled: false))
    }

    @Test func dueOnceADayOld() {
        #expect(!ExtensionUpdatePolicy.shouldCheck(lastCheck: now, now: now, enabled: true))
        #expect(!ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(23.9), now: now, enabled: true))
        #expect(ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(24), now: now, enabled: true))
        #expect(ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(100), now: now, enabled: true))
    }

    @Test func aCheckInTheFutureMeansTheClockWasWrong() {
        #expect(ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(-48), now: now, enabled: true))
        #expect(!ExtensionUpdatePolicy.shouldCheck(lastCheck: hoursAgo(-1), now: now, enabled: true))
    }
}
