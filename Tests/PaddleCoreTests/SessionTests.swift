import Foundation
@testable import PaddleCore
import Testing

struct SessionTests {
    @Test func roundTrips() throws {
        let session = SessionRecord(windows: [
            WindowRecord(tabs: [
                TabRecord(url: "https://a.test", title: "A", isPinned: true, interactionState: Data([1, 2, 3])),
                TabRecord(url: "https://b.test", title: "B"),
            ], selectedIndex: 1, frame: "{{0, 0}, {800, 600}}"),
        ])
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(SessionRecord.self, from: data) == session)
    }
}
