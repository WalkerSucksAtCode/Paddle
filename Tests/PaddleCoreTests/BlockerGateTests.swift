import Foundation
@testable import PaddleCore
import Testing

@MainActor
struct BlockerGateTests {
    @Test func opensWhenReadyAndResumesWaiters() async {
        let gate = BlockerGate(timeout: .seconds(60))
        #expect(!gate.isOpen)
        let waiter = Task { await gate.wait() }
        await Task.yield()
        #expect(gate.markReady() == false)
        await waiter.value
        #expect(gate.state == .ready)
        #expect(gate.isOpen && gate.isReady)
    }

    @Test func opensOnTimeoutThenReadyReportsLate() async {
        let gate = BlockerGate(timeout: .milliseconds(20))
        await gate.wait()  // starts the timeout itself
        #expect(gate.state == .timedOut)
        #expect(gate.isOpen && !gate.isReady)
        #expect(gate.markReady() == true)
        #expect(gate.isReady)
        #expect(gate.markReady() == false)  // only once
    }

    @Test func waitAfterOpenReturnsAtOnce() async {
        let gate = BlockerGate(timeout: .seconds(60))
        gate.markReady()
        await gate.wait()
        #expect(gate.state == .ready)
    }

    @Test func readyBeforeTimeoutStaysReady() async throws {
        let gate = BlockerGate(timeout: .milliseconds(20))
        gate.start()
        gate.markReady()
        try await Task.sleep(for: .milliseconds(60))
        #expect(gate.state == .ready)
    }

    @Test func everyWaiterResumes() async {
        let gate = BlockerGate(timeout: .milliseconds(20))
        async let a: Void = gate.wait()
        async let b: Void = gate.wait()
        async let c: Void = gate.wait()
        _ = await (a, b, c)
        #expect(gate.state == .timedOut)
    }
}

struct UnblockedReloadTests {
    @Test func reloadsOnlyPlainUnblockedPages() {
        #expect(UnblockedReload.decide(loadedUnblocked: true, isPost: false, isBusy: false, userTyped: false) == .reload)
        #expect(UnblockedReload.decide(loadedUnblocked: false, isPost: false, isBusy: false, userTyped: false) == .skip(.notUnblocked))
        #expect(UnblockedReload.decide(loadedUnblocked: true, isPost: true, isBusy: false, userTyped: false) == .skip(.post))
        #expect(UnblockedReload.decide(loadedUnblocked: true, isPost: false, isBusy: true, userTyped: false) == .skip(.busy))
        #expect(UnblockedReload.decide(loadedUnblocked: true, isPost: false, isBusy: false, userTyped: true) == .skip(.typed))
    }
}

struct BundledFilterSnapshotsTests {
    @Test func onlyDefaultListsHaveSnapshots() {
        #expect(BundledFilterSnapshots.fileName(forList: "https://easylist.to/easylist/easylist.txt") == "easylist.txt")
        #expect(BundledFilterSnapshots.fileName(forList: "https://easylist.to/easylist/easyprivacy.txt") == "easyprivacy.txt")
        #expect(BundledFilterSnapshots.fileName(forList: "https://example.com/easylist.txt") == nil)
    }

    @Test func readsVersionStampAsUTC() {
        let header = "[Adblock Plus 2.0]\n! Version: 202610121715\n! Title: EasyList\n||ads.example^\n"
        let date = BundledFilterSnapshots.versionDate(header[...])
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-12T17:15:00Z"))
    }

    @Test func missingOrMalformedStampIsNil() {
        #expect(BundledFilterSnapshots.versionDate("[Adblock Plus 2.0]\n! Title: X\n"[...]) == nil)
        #expect(BundledFilterSnapshots.versionDate("! Version: 2026101217\n"[...]) == nil)
        #expect(BundledFilterSnapshots.versionDate("! Version: 202613121715\n"[...]) == nil)
    }
}
