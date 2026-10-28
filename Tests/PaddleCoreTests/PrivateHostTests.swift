@testable import PaddleCore
import Testing

struct PrivateHostTests {
    @Test(arguments: [
        "localhost", "LOCALHOST", "localhost.", "app.localhost", "printer.local", "nas.local.",
        "127.0.0.1", "127.255.0.9", "0.0.0.0", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
        "169.254.169.254", "100.64.0.1", "100.127.255.255",
        "::1", "[::1]", "::", "fc00::1", "fd12:3456::1", "fe80::1", "fe80::1%en0", "febf::1",
        "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:c0a8:0101", "[::ffff:192.168.0.1]",
        "2130706433", "0x7f000001", "017700000001", "0x7f.1", "127.1", "0177.0.0.1", "0xc0.0xa8.1.1", "192.168.257",
    ])
    func privateHosts(_ host: String) {
        #expect(PrivateHost.isPrivate(host), "\(host)")
    }

    @Test(arguments: [
        "example.com", "www.example.co.uk", "localhost.example.com", "notlocal", "mylocal.com", "",
        "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.167.1.1", "100.63.0.1", "100.128.0.1", "169.253.0.1", "11.0.0.1",
        "2606:4700::1111", "fec0::1", "fe00::1", "::ffff:8.8.8.8", "[2001:db8::1]",
        "1.2.3.4.5", "256.1.1.1", "999999999999", "0xZZ", "08.1.1.1",
    ])
    func publicHosts(_ host: String) {
        #expect(!PrivateHost.isPrivate(host), "\(host)")
    }

    @Test func parsesIPv4Spellings() {
        #expect(PrivateHost.parseIPv4("2130706433") == 0x7F00_0001)
        #expect(PrivateHost.parseIPv4("0x7f.0.0.1") == 0x7F00_0001)
        #expect(PrivateHost.parseIPv4("0177.0.0.01") == 0x7F00_0001)
        #expect(PrivateHost.parseIPv4("10.1") == 0x0A00_0001)
        #expect(PrivateHost.parseIPv4("example.com") == nil)
    }
}
