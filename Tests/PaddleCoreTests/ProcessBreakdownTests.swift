import Foundation
@testable import PaddleCore
import Testing

struct ProcessBreakdownTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func rowsPartitionEveryProcess() {
        let owners: [String: ViewOwner] = ["va": .tab(a), "vb": .tab(b), "bg": .extensionView, "popup": .extensionView]
        let processes = [
            WebContentProcess(pid: 1, footprint: 100, views: ["va"]),
            WebContentProcess(pid: 2, footprint: 50, views: ["vb"]),
            WebContentProcess(pid: 3, footprint: 200, views: ["bg", "popup"]),
            WebContentProcess(pid: 4, footprint: 30, views: [], runsServiceWorkers: true),
            WebContentProcess(pid: 5, footprint: 20, views: [], runsSharedWorkers: true),
            WebContentProcess(pid: 6, footprint: 10, views: []),  // back-forward cache / prewarmed
            WebContentProcess(pid: 7, footprint: 7, views: ["gone"]),  // a view nobody owns any more
        ]
        let result = ProcessBreakdown.aggregate(processes: processes, owners: owners, gpu: 40, networking: [60, 1], app: 300)
        #expect(result.tabs == 150)
        #expect(result.extensions == 200)
        #expect(result.serviceWorkers == 50)
        #expect(result.shared == 101)
        #expect(result.app == 300)
        #expect(result.other == 17)
        #expect(result.total == 150 + 200 + 50 + 101 + 300 + 17)
        #expect(result.perTab == [a: 100, b: 50])
        #expect(result.sharedTabs.isEmpty)
    }

    @Test func tabsSharingAProcessGetTheWholeFootprintAndAreMarked() {
        let owners: [Int: ViewOwner] = [1: .tab(a), 2: .tab(b), 3: .tab(c)]
        let processes = [
            WebContentProcess(pid: 10, footprint: 120, views: [1, 2]),
            WebContentProcess(pid: 11, footprint: 30, views: [3]),
        ]
        let result = ProcessBreakdown.aggregate(processes: processes, owners: owners)
        #expect(result.perTab == [a: 120, b: 120, c: 30])
        #expect(result.sharedTabs == [a, b])
        #expect(result.tabs == 150)
        #expect(result.total == 150)
    }

    @Test func tabSplitAcrossProcessesSumsThem() {
        // Site isolation would give one tab several processes; each is counted once for the tab.
        let owners: [Int: ViewOwner] = [1: .tab(a)]
        let processes = [
            WebContentProcess(pid: 10, footprint: 100, views: [1]),
            WebContentProcess(pid: 11, footprint: 25, views: [1]),
        ]
        let result = ProcessBreakdown.aggregate(processes: processes, owners: owners)
        #expect(result.perTab == [a: 125])
        #expect(result.sharedTabs.isEmpty)
    }

    @Test func mixedTabAndExtensionViewsCountAsTab() {
        let owners: [Int: ViewOwner] = [1: .tab(a), 2: .extensionView]
        let result = ProcessBreakdown.aggregate(processes: [WebContentProcess(pid: 1, footprint: 9, views: [1, 2])], owners: owners)
        #expect(result.tabs == 9)
        #expect(result.extensions == 0)
    }

    @Test func workersInATabProcessStayUnderTabs() {
        let owners: [Int: ViewOwner] = [1: .tab(a)]
        let result = ProcessBreakdown.aggregate(
            processes: [WebContentProcess(pid: 1, footprint: 9, views: [1], runsServiceWorkers: true)], owners: owners
        )
        #expect(result.tabs == 9)
        #expect(result.serviceWorkers == 0)
    }

    @Test func repeatedPidCountsOnce() {
        let owners: [Int: ViewOwner] = [1: .tab(a)]
        let processes = [
            WebContentProcess(pid: 1, footprint: 10, views: [1]),
            WebContentProcess(pid: 1, footprint: 10, views: [1]),
        ]
        let result = ProcessBreakdown.aggregate(processes: processes, owners: owners)
        #expect(result.tabs == 10)
        #expect(result.perTab == [a: 10])
    }

    @Test func emptyInputIsAllZero() {
        let result = ProcessBreakdown.aggregate(processes: [WebContentProcess<Int>](), owners: [:])
        #expect(result == ProcessBreakdown())
        #expect(result.total == 0)
    }

    @Test func sleepingTabsHaveNoRow() {
        // A tab without a web view has no view in `owners` and so no `perTab` entry.
        let owners: [Int: ViewOwner] = [1: .tab(a)]
        let result = ProcessBreakdown.aggregate(processes: [WebContentProcess(pid: 1, footprint: 5, views: [1])], owners: owners)
        #expect(result.perTab[b] == nil)
    }
}
