import Foundation
import PaddleCore
import Testing

struct ServiceWorkerWatchdogTests {
    @Test func registrationCoversHostAndSubdomains() {
        let sites: Set<String> = ["reddit.com", "127.0.0.1"]
        #expect(ServiceWorkerWatchdog.hasRegistration(for: "www.reddit.com", in: sites))
        #expect(ServiceWorkerWatchdog.hasRegistration(for: "Reddit.com", in: sites))
        #expect(ServiceWorkerWatchdog.hasRegistration(for: "127.0.0.1", in: sites))
        #expect(!ServiceWorkerWatchdog.hasRegistration(for: "notreddit.com", in: sites))
        #expect(!ServiceWorkerWatchdog.hasRegistration(for: "x.com", in: sites))
        #expect(!ServiceWorkerWatchdog.hasRegistration(for: "", in: sites))
        #expect(!ServiceWorkerWatchdog.hasRegistration(for: "a.com", in: [""]))
    }

    @Test func stopsOnlyWithARegistrationAndOncePerCooldown() {
        var watchdog = ServiceWorkerWatchdog(cooldown: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(watchdog.shouldStop(host: "slow.example", registeredSites: ["reddit.com"], now: start) == false)
        #expect(watchdog.shouldStop(host: "www.reddit.com", registeredSites: ["reddit.com"], now: start) == true)
        #expect(watchdog.shouldStop(host: "www.reddit.com", registeredSites: ["reddit.com"], now: start.addingTimeInterval(10)) == false)
        #expect(watchdog.shouldStop(host: "www.reddit.com", registeredSites: ["reddit.com"], now: start.addingTimeInterval(31)) == true)
    }

    @Test func aRefusedHostDoesNotStartTheCooldown() {
        var watchdog = ServiceWorkerWatchdog(cooldown: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(watchdog.shouldStop(host: "slow.example", registeredSites: [], now: start) == false)
        #expect(watchdog.shouldStop(host: "x.com", registeredSites: ["x.com"], now: start.addingTimeInterval(1)) == true)
    }
}
