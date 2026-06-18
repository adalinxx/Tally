import Testing
import Foundation
@testable import Tally

@Suite("AdmissionController")
struct AdmissionControllerTests {

    @Test("Token bucket consumes then denies, refills over time")
    func testTokenBucketConsumeRefill() {
        var admission = AdmissionController(config: TallyConfig(
            perPeerRequestCapacity: 2,
            perPeerRequestRefillPerSecond: 100
        ))
        let peer = PeerID(publicKey: "bucket")
        let t0 = ContinuousClock.now

        let a = admission.consumeRequestToken(peer: peer, at: t0)
        let b = admission.consumeRequestToken(peer: peer, at: t0)
        let c = admission.consumeRequestToken(peer: peer, at: t0)
        #expect(a)
        #expect(b)
        #expect(!c)

        // After 1s at 100 tokens/s the bucket has refilled (capped at capacity).
        let d = admission.consumeRequestToken(peer: peer, at: t0.advanced(by: .seconds(1)))
        #expect(d)
    }

    @Test("No refill means bucket stays empty")
    func testTokenBucketNoRefill() {
        var admission = AdmissionController(config: TallyConfig(
            perPeerRequestCapacity: 1,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "norefill")
        let t0 = ContinuousClock.now
        let first = admission.consumeRequestToken(peer: peer, at: t0)
        let second = admission.consumeRequestToken(peer: peer, at: t0.advanced(by: .seconds(10)))
        #expect(first)
        #expect(!second)
    }

    @Test("Pressure gate fails closed for unknown (zero-rep) peer at full pressure")
    func testPressureGateFailsClosed() {
        let admission = AdmissionController(config: .default)
        // pressure >= 1.0 requires rep >= 0.8; a fresh peer scores 0 → denied.
        #expect(!admission.passesPressureGate(reputation: 0, pressure: 1.0))
        #expect(admission.passesPressureGate(reputation: 0.8, pressure: 1.0))
    }

    @Test("Pressure gate scales threshold between 0.5 and 1.0")
    func testPressureGateScaledThreshold() {
        let admission = AdmissionController(config: .default)
        // pressure 0.75 → threshold (0.75 - 0.5) * 2 = 0.5
        #expect(!admission.passesPressureGate(reputation: 0.49, pressure: 0.75))
        #expect(admission.passesPressureGate(reputation: 0.5, pressure: 0.75))
    }

    @Test("Rate pressure reflects recorded window bytes")
    func testRatePressure() {
        var admission = AdmissionController(config: TallyConfig(rateLimitBytesPerSecond: 1000))
        let t0 = ContinuousClock.now
        admission.recordWindowByte(500, at: t0)
        let pressure = admission.ratePressure(at: t0.advanced(by: .milliseconds(1)))
        #expect(pressure > 0)
    }

    @Test("Rate pressure expires stale read window")
    func testRatePressureExpiresStaleWindowOnRead() {
        var admission = AdmissionController(config: TallyConfig(
            rateLimitBytesPerSecond: 1000,
            rateWindow: 1
        ))
        let t0 = ContinuousClock.now
        admission.recordWindowByte(10_000, at: t0)

        let initialPressure = admission.ratePressure(at: t0.advanced(by: .milliseconds(1)))
        let expiredPressure = admission.ratePressure(at: t0.advanced(by: .seconds(2)))
        #expect(initialPressure > 0)
        #expect(expiredPressure == 0)
        #expect(admission.windowBytesSent == 0)
    }
}

@Suite("ChallengeService")
struct ChallengeServiceTests {

    @Test("Issued challenge uses configured difficulty")
    func testIssueDifficulty() {
        var service = ChallengeService(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "issued")
        let challenge = service.issue(for: peer)
        #expect(challenge.difficulty == 4)
        #expect(challenge.boundPeer == peer)
    }

    @Test("Verify accepts a correct solution and rejects a wrong one")
    func testVerifyAcceptReject() {
        var service = ChallengeService(config: TallyConfig(challengeDifficulty: 16))
        let peer = PeerID(publicKey: "service")
        let challenge = service.issue(for: peer)
        let solution = ChallengeSolver().solve(challenge)
        let wrong = service.verify(challenge, solution: Data([0xFF, 0xFF, 0xFF, 0xFF]), peer: peer)
        let accepted = service.verify(challenge, solution: solution, peer: peer)
        let replay = service.verify(challenge, solution: solution, peer: peer)
        #expect(!wrong)
        #expect(accepted)
        #expect(!replay)
    }
}

@Suite("ReputationScorer")
struct ReputationScorerTests {

    @Test("Unknown/new peer scores zero")
    func testNewPeerZero() {
        let scorer = ReputationScorer(config: .default)
        var ledger = PeerLedger(now: .now)
        let rep = scorer.score(&ledger, peer: PeerID(publicKey: "new"), at: .now)
        #expect(rep == 0)
    }
}
