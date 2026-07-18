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

    @Test("Reset clears only one peer and preserves lifetime metrics")
    func resetPeer() {
        let tally = Tally(config: TallyConfig(
            challengeDifficulty: 0,
            perPeerRequestCapacity: 1,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "reset")
        let control = PeerID(publicKey: "control")
        tally.recordReceived(peer: peer, bytes: 100)
        tally.recordReceived(peer: control, bytes: 100)
        #expect(tally.shouldAllow(peer: peer))
        #expect(tally.shouldAllow(peer: control))
        #expect(!tally.shouldAllow(peer: peer))
        let challenge = tally.issueChallenge(for: peer)
        let controlChallenge = tally.issueChallenge(for: control)
        let metrics = tally.metrics

        tally.resetPeer(peer)

        #expect(tally.metrics == metrics)
        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.admissionScore(for: control) > 0)
        #expect(tally.peerCount == 1)
        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.shouldAllow(peer: control))
        #expect(!tally.verifyChallenge(challenge, solution: Data(), peer: peer))
        #expect(tally.verifyChallenge(controlChallenge, solution: Data(), peer: control))
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

    @Test("Evidence storage evicts least-recently-used state and restarts fresh")
    func boundedEvidence() {
        let config = TallyConfig(maxPeers: 1)
        let tally = Tally(config: config)
        let peers = (0...config.boundedPeerStateCapacity).map {
            PeerID(publicKey: "bounded-peer-\($0)")
        }

        for peer in peers.dropLast() {
            tally.recordReceived(peer: peer, bytes: 1)
        }
        #expect(tally.admissionScore(for: peers[0]) > 0)
        tally.recordReceived(peer: peers.last!, bytes: 1)

        #expect(tally.peerCount == config.boundedPeerStateCapacity)
        #expect(tally.admissionScore(for: peers[0]) > 0)
        #expect(tally.admissionScore(for: peers[1]) == 0)

        tally.recordReceived(peer: peers[1], bytes: 1)
        #expect(tally.admissionScore(for: peers[1]) > 0)
        #expect(tally.peerCount == config.boundedPeerStateCapacity)
    }

    @Test("Shared Tally updates remain atomic under concurrent saturation")
    func concurrentSaturatingWorkload() async {
        let taskCount = 16
        let iterations = 64
        let operations = taskCount * iterations
        let tally = Tally(config: TallyConfig(
            rateLimitBytesPerSecond: 1e30,
            perPeerRequestCapacity: Double(operations),
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "concurrent")
        let start = OneShotBarrier(participantCount: taskCount)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    await start.wait()
                    for _ in 0..<iterations {
                        tally.recordSent(peer: peer, bytes: .max)
                        tally.recordReceived(peer: peer, bytes: .max)
                        _ = tally.shouldAllow(peer: peer)
                    }
                }
            }
        }

        #expect(tally.metrics.totalBytesSent == .max)
        #expect(tally.metrics.totalBytesReceived == .max)
        #expect(tally.metrics.allowed == operations)
        #expect(tally.metrics.denied == 0)
        #expect(tally.peerCount == 1)
        #expect(tally.admissionScore(for: peer).isFinite)
        #expect(tally.ratePressure().isFinite)
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
        let caseRaw = String(repeating: "ab", count: 32)
        let uppercase = caseRaw.uppercased()
        let malformed = "ed01" + "0000000000000000000000000000000000000000000000000000000000004afg"

        #expect(KeyDifficulty.canonicalRawHex("ed01" + raw) == raw)
        #expect(KeyDifficulty.canonicalRawHex("ED01" + uppercase) == caseRaw)
        #expect(KeyDifficulty.canonicalRawHex(uppercase) == caseRaw)
        #expect(KeyDifficulty.keyWorkBits("ed01" + raw) == KeyDifficulty.keyWorkBits(raw))
        #expect(KeyDifficulty.keyWorkBits(raw) >= 8)
        #expect(PeerID(publicKey: "ED01" + uppercase) == PeerID(publicKey: caseRaw))
        #expect(PeerID(publicKey: uppercase).trailingZeroBits == KeyDifficulty.keyWorkBits(caseRaw))
        #expect(KeyDifficulty.canonicalRawHex(malformed) == malformed)
        #expect(KeyDifficulty.keyWorkBits(malformed) == 0)
        #expect(KeyDifficulty.baseTrust(publicKey: malformed) == 0)
    }
}
