@testable import PaddleCore
import Testing

struct PeerRequirementTests {
    @Test func requirementNamesIdentifierAndTeam() {
        #expect(
            PeerRequirement.requirementString()
                == "anchor apple generic and identifier \"paddle-mcp\" and certificate leaf[subject.OU] = \"VB3UP263YT\""
        )
    }

    @Test func requirementRefusesCharactersThatChangeItsMeaning() {
        #expect(PeerRequirement.requirementString(identifier: "a\" or anchor apple", team: "VB3UP263YT") == nil)
        #expect(PeerRequirement.requirementString(identifier: "paddle-mcp", team: "X\"") == nil)
        #expect(PeerRequirement.requirementString(identifier: "", team: "VB3UP263YT") == nil)
    }

    @Test func acceptsOnlyAValidSignedSameUserPeer() {
        #expect(PeerRequirement.verdict(peerUID: 501, ownUID: 501, peerPID: 123, signatureValid: true) == .accept)
    }

    @Test func refusesEverythingElse() {
        func refused(_ v: PeerRequirement.Verdict) -> Bool { if case .refuse = v { true } else { false } }
        #expect(refused(PeerRequirement.verdict(peerUID: 502, ownUID: 501, peerPID: 123, signatureValid: true)))
        #expect(refused(PeerRequirement.verdict(peerUID: nil, ownUID: 501, peerPID: 123, signatureValid: true)))
        #expect(refused(PeerRequirement.verdict(peerUID: 501, ownUID: 501, peerPID: nil, signatureValid: true)))
        #expect(refused(PeerRequirement.verdict(peerUID: 501, ownUID: 501, peerPID: 0, signatureValid: true)))
        #expect(refused(PeerRequirement.verdict(peerUID: 501, ownUID: 501, peerPID: 123, signatureValid: nil)))
        #expect(refused(PeerRequirement.verdict(peerUID: 501, ownUID: 501, peerPID: 123, signatureValid: false)))
    }
}
