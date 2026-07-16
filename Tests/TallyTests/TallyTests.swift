import Foundation
import Testing
@testable import Tally

@Suite("Tally")
struct TallyTests {
    @Test("Unknown peer has zero score and admission does not create evidence")
    func unknownPeer() {
        let tally = Tally()
        let peer = PeerID(publicKey: "unknown")

        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.shouldAllow(peer: peer))
        #expect(tally.peerCount == 0)
    }

    @Test("Raw received bytes earn admission score")
    func receivedBytesEarnScore() {
        let tally = Tally(config: TallyConfig(exchangeBaseline: 100))
        let peer = PeerID(publicKey: "peer-0")

        tally.recordReceived(peer: peer, bytes: 100)

        #expect(tally.admissionScore(for: peer) > 0.49)
        #expect(tally.admissionScore(for: peer) < 0.51)
        #expect(tally.peerCount == 1)
        #expect(tally.metrics.totalBytesReceived == 100)
    }

    @Test("Attributable protocol violation reduces score")
    func protocolViolationPenalty() {
        let tally = Tally(config: TallyConfig(exchangeBaseline: 1))
        let peer = PeerID(publicKey: "peer-0")
        tally.recordReceived(peer: peer, bytes: 100)
        let clean = tally.admissionScore(for: peer)

        tally.recordProtocolViolation(peer: peer)
        let penalized = tally.admissionScore(for: peer)

        #expect(penalized < clean)
        #expect(abs(clean - 2 * penalized) < 0.001)
    }

    @Test("Lack of violations is not positive evidence")
    func noPositiveProofFromViolationCounter() {
        let tally = Tally()
        let peer = PeerID(publicKey: "violation-only")

        tally.recordProtocolViolation(peer: peer)

        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.peerCount == 1)
    }

    @Test("Excessive requests are token-bucket denial only")
    func excessiveRequestsOnlyConsumeTokens() {
        let tally = Tally(config: TallyConfig(
            perPeerRequestCapacity: 2,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "burst")

        #expect(tally.shouldAllow(peer: peer))
        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.shouldAllow(peer: peer))
        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.peerCount == 0)
        #expect(tally.metrics.allowed == 2)
        #expect(tally.metrics.denied == 1)
    }

    @Test("Unknown peer is denied under send-rate pressure")
    func unknownPeerDeniedUnderPressure() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 100))
        tally.recordSent(peer: PeerID(publicKey: "load"), bytes: 500)
        let unknown = PeerID(publicKey: "unknown-under-pressure")

        #expect(tally.ratePressure() >= 1)
        #expect(!tally.shouldAllow(peer: unknown))
        #expect(tally.admissionScore(for: unknown) == 0)
    }

    @Test("Strong exchange, challenge, and key work pass under pressure")
    func strongEvidencePassesUnderPressure() throws {
        let tally = Tally(config: TallyConfig(
            challengeDifficulty: 4,
            rateLimitBytesPerSecond: 100,
            hardnessBaseline: 4,
            exchangeBaseline: 1,
            powBaseline: 16
        ))
        let peer = PeerID(publicKey: "peer-4587")
        tally.recordReceived(peer: peer, bytes: 100)
        let challenge = tally.issueChallenge(for: peer)
        let solution = try #require(ChallengeSolver().solve(challenge))
        #expect(tally.verifyChallenge(challenge, solution: solution, peer: peer))
        tally.recordSent(peer: PeerID(publicKey: "load"), bytes: 500)

        #expect(tally.admissionScore(for: peer) > 0.99)
        #expect(tally.shouldAllow(peer: peer))
    }

    @Test("Reset clears evidence, request tokens, and outstanding challenges")
    func resetPeer() throws {
        let tally = Tally(config: TallyConfig(
            challengeDifficulty: 4,
            perPeerRequestCapacity: 1,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "reset")
        tally.recordReceived(peer: peer, bytes: 100)
        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.shouldAllow(peer: peer))
        let challenge = tally.issueChallenge(for: peer)
        let solution = try #require(ChallengeSolver().solve(challenge))

        tally.resetPeer(peer)

        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.peerCount == 0)
        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.verifyChallenge(challenge, solution: solution, peer: peer))
    }

    @Test("Non-positive byte counts are ignored")
    func invalidByteCounts() {
        let tally = Tally()
        let peer = PeerID(publicKey: "invalid-bytes")

        tally.recordSent(peer: peer, bytes: 0)
        tally.recordSent(peer: peer, bytes: -1)
        tally.recordReceived(peer: peer, bytes: 0)
        tally.recordReceived(peer: peer, bytes: -1)

        #expect(tally.peerCount == 0)
        #expect(tally.metrics.totalBytesSent == 0)
        #expect(tally.metrics.totalBytesReceived == 0)
    }

    @Test("Byte counters saturate instead of trapping")
    func byteCountersSaturate() {
        let tally = Tally()
        let peer = PeerID(publicKey: "large-counter")

        tally.recordSent(peer: peer, bytes: .max)
        tally.recordSent(peer: peer, bytes: 1)
        tally.recordReceived(peer: peer, bytes: .max)
        tally.recordReceived(peer: peer, bytes: 1)

        #expect(tally.metrics.totalBytesSent == .max)
        #expect(tally.metrics.totalBytesReceived == .max)
        #expect(tally.ratePressure().isFinite)
    }

    @Test("Evidence storage remains bounded")
    func boundedEvidence() {
        let config = TallyConfig(maxPeers: 1)
        let tally = Tally(config: config)

        for index in 0...config.boundedPeerStateCapacity {
            tally.recordReceived(peer: PeerID(publicKey: "peer-\(index)"), bytes: 1)
        }

        #expect(tally.peerCount == config.boundedPeerStateCapacity)
    }

    @Test("PeerID trailing zero bits use SHA-256")
    func peerIDTrailingZeroBits() {
        #expect(PeerID(publicKey: "abc").trailingZeroBits == 0)
        #expect(PeerID(publicKey: "abc123").trailingZeroBits == 4)
        #expect(PeerID(publicKey: "peer-4587").trailingZeroBits == 17)
    }

    @Test("Canonical and raw key spellings have equal key work")
    func canonicalKeyWork() {
        let raw = "0000000000000000000000000000000000000000000000000000000000000059"

        #expect(KeyDifficulty.canonicalRawHex("ed01" + raw) == raw)
        #expect(KeyDifficulty.keyWorkBits("ed01" + raw) == KeyDifficulty.keyWorkBits(raw))
        #expect(KeyDifficulty.keyWorkBits(raw) >= 8)
    }
}
