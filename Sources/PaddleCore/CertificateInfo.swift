import Foundation
import Security

/// Certificate details extracted from a TLS connection's SecTrust.
public struct CertificateInfo: Sendable, Equatable {
    public var subject: String
    public var issuer: String
    public var isValid: Bool

    public init(subject: String, issuer: String = "", isValid: Bool = true) {
        self.subject = subject
        self.issuer = issuer
        self.isValid = isValid
    }

    /// Reads certificate summary, issuer, and validity from an evaluated `SecTrust`.
    public static func read(from trust: SecTrust) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let cert = chain.first else {
            return nil
        }
        let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""
        let issuer = chain.count > 1 ? ((SecCertificateCopySubjectSummary(chain[1]) as String?) ?? "") : ""
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(trust, &error)
        return CertificateInfo(subject: subject, issuer: issuer, isValid: isValid)
    }
}
