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

    @Test("Pressure gate fails closed for unknown peer at full pressure")
    func testPressureGateFailsClosed() {
        let admission = AdmissionController(config: .default)
        #expect(!admission.passesPressureGate(admissionScore: 0, pressure: 1.0))
        #expect(admission.passesPressureGate(admissionScore: 0.8, pressure: 1.0))
    }

    @Test("Pressure gate scales threshold between 0.5 and 1.0")
    func testPressureGateScaledThreshold() {
        let admission = AdmissionController(config: .default)
        #expect(!admission.passesPressureGate(admissionScore: 0.39, pressure: 0.75))
        #expect(admission.passesPressureGate(admissionScore: 0.4, pressure: 0.75))
    }

    @Test("Pressure never makes admission easier")
    func testPressureGateIsMonotonic() {
        let admission = AdmissionController(config: .default)
        for step in 0...100 {
            let score = Double(step) / 100
            var denied = false
            for pressureStep in 50...200 {
                let pressure = Double(pressureStep) / 100
                let allowed = admission.passesPressureGate(admissionScore: score, pressure: pressure)
                if denied { #expect(!allowed) }
                if !allowed { denied = true }
            }
        }
    }

    @Test("Rate pressure reflects recorded window bytes")
    func testRatePressure() {
        var admission = AdmissionController(config: TallyConfig(rateLimitBytesPerSecond: 1000))
        let t0 = ContinuousClock.now
        admission.recordSentBytes(500, at: t0)
        let pressure = admission.ratePressure(at: t0.advanced(by: .milliseconds(1)))
        #expect(pressure > 0)
    }

    @Test("Sub-millisecond windows use their configured byte budget")
    func testSubMillisecondRateWindow() {
        var admission = AdmissionController(config: TallyConfig(
            rateLimitBytesPerSecond: 1_000,
            rateWindow: 0.0001
        ))
        let t0 = ContinuousClock.now
        admission.recordSentBytes(1, at: t0)
        #expect(admission.ratePressure(at: t0.advanced(by: .microseconds(50))) == 2)
    }

    @Test("Rate pressure expires stale read window")
    func testRatePressureExpiresStaleWindowOnRead() {
        var admission = AdmissionController(config: TallyConfig(
            rateLimitBytesPerSecond: 1000,
            rateWindow: 1
        ))
        let t0 = ContinuousClock.now
        admission.recordSentBytes(10_000, at: t0)

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
    func testVerifyAcceptReject() throws {
        var service = ChallengeService(config: TallyConfig(challengeDifficulty: 16))
        let peer = PeerID(publicKey: "service")
        let challenge = service.issue(for: peer)
        let solution = try #require(ChallengeSolver().solve(challenge))
        let wrong = service.verify(challenge, solution: Data([0xFF, 0xFF, 0xFF, 0xFF]), peer: peer)
        let accepted = service.verify(challenge, solution: solution, peer: peer)
        let replay = service.verify(challenge, solution: solution, peer: peer)
        #expect(!wrong)
        #expect(accepted)
        #expect(!replay)
    }
}
