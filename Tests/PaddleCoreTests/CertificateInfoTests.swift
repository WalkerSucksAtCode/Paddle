import Foundation
@testable import PaddleCore
import Security
import Testing

struct CertificateInfoTests {
    @Test func certificateInfoInitialization() {
        let info = CertificateInfo(subject: "example.com", issuer: "Test CA", isValid: true)
        #expect(info.subject == "example.com")
        #expect(info.issuer == "Test CA")
        #expect(info.isValid)
    }

    @Test func certificateInfoEquality() {
        let info1 = CertificateInfo(subject: "example.com", issuer: "CA 1", isValid: true)
        let info2 = CertificateInfo(subject: "example.com", issuer: "CA 1", isValid: true)
        let info3 = CertificateInfo(subject: "example.com", issuer: "CA 2", isValid: false)
        #expect(info1 == info2)
        #expect(info1 != info3)
    }
}
