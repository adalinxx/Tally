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

    @Test("Request buckets evict the least-recently-used peer and restart fresh")
    func boundedRequestBuckets() {
        let config = TallyConfig(
            perPeerRequestCapacity: 1,
            perPeerRequestRefillPerSecond: 0,
            maxPeers: 1
        )
        var admission = AdmissionController(config: config)
        let peers = (0...config.boundedPeerStateCapacity).map {
            PeerID(publicKey: "bucket-peer-\($0)")
        }
        let now = ContinuousClock.now

        for peer in peers.dropLast() {
            let allowed = admission.consumeRequestToken(peer: peer, at: now)
            #expect(allowed)
        }
        let touched = admission.consumeRequestToken(peer: peers[0], at: now)
        let newcomer = admission.consumeRequestToken(peer: peers.last!, at: now)
        #expect(!touched)
        #expect(newcomer)

        #expect(admission.requestBuckets.count == config.boundedPeerStateCapacity)
        #expect(admission.requestBuckets.value(forKey: peers[0]) != nil)
        #expect(admission.requestBuckets.value(forKey: peers[1]) == nil)
        let restarted = admission.consumeRequestToken(peer: peers[1], at: now)
        #expect(restarted)
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

    @Test("Seeded admission operations match the token and pressure models")
    func seededAdmissionOperations() {
        var random = SeededGenerator(defaultSeed: 0xad01_5510)
        let seed = random.state
        let config = TallyConfig(
            rateLimitBytesPerSecond: 1_000,
            rateWindow: 2,
            perPeerRequestCapacity: 3,
            perPeerRequestRefillPerSecond: 2,
            maxPeers: 1_000
        )
        var admission = AdmissionController(config: config)
        let peer = PeerID(publicKey: "seeded-admission")
        var now = ContinuousClock.now
        admission.windowStart = now

        var hasBucket = false
        var tokens = config.perPeerRequestCapacity
        var lastRefill = now
        var windowBytes = 0
        var windowStart = now

        for step in 0..<500 {
            now = now.advanced(by: .milliseconds(Int64(random.index(upperBound: 1_000))))

            switch random.index(upperBound: 4) {
            case 0:
                if !hasBucket {
                    hasBucket = true
                    tokens = config.perPeerRequestCapacity
                    lastRefill = now
                } else {
                    let elapsed = seconds(from: lastRefill, to: now)
                    if elapsed > 0 {
                        tokens = min(
                            config.perPeerRequestCapacity,
                            tokens + elapsed * config.perPeerRequestRefillPerSecond
                        )
                        lastRefill = now
                    }
                }
                let expected = tokens >= 1
                if expected { tokens -= 1 }
                #expect(
                    admission.consumeRequestToken(peer: peer, at: now) == expected,
                    "seed \(seed), step \(step)"
                )

            case 1:
                admission.removePeer(peer)
                hasBucket = false

            case 2:
                let bytes = random.index(upperBound: 500)
                if seconds(from: windowStart, to: now) >= config.rateWindow {
                    windowBytes = bytes
                    windowStart = now
                } else {
                    windowBytes += bytes
                }
                admission.recordSentBytes(bytes, at: now)

            default:
                let expected: Double
                if seconds(from: windowStart, to: now) >= config.rateWindow {
                    windowBytes = 0
                    windowStart = now
                    expected = 0
                } else {
                    expected = min(
                        Double(windowBytes) / (config.rateLimitBytesPerSecond * config.rateWindow),
                        2
                    )
                }
                #expect(
                    abs(admission.ratePressure(at: now) - expected) < 0.000_000_001,
                    "seed \(seed), step \(step)"
                )
            }

            #expect(
                admission.requestBuckets.count <= config.boundedPeerStateCapacity,
                "seed \(seed), step \(step)"
            )
        }
    }

    private func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let elapsed = start.duration(to: end).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
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

    @Test("Verify accepts the known answer and consumes it once")
    func verifyKnownAnswerAndReplay() {
        var service = ChallengeService(config: TallyConfig(challengeDifficulty: 16))
        let now = ContinuousClock.now
        let challenge = service.issue(
            for: ChallengeKnownAnswer.peer,
            nonce: ChallengeKnownAnswer.nonce,
            at: now
        )
        let wrong = service.verify(
            challenge,
            solution: ChallengeKnownAnswer.invalidSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        )
        let accepted = service.verify(
            challenge,
            solution: ChallengeKnownAnswer.validSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        )
        let replay = service.verify(
            challenge,
            solution: ChallengeKnownAnswer.validSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        )
        #expect(!wrong)
        #expect(accepted)
        #expect(!replay)
        #expect(service.outstandingCount == 0)
    }

    @Test("Stored challenges actually expire and are pruned")
    func storedChallengeExpiryAndCleanup() {
        var service = ChallengeService(config: TallyConfig(
            challengeDifficulty: 0,
            challengeExpiration: .seconds(5)
        ))
        let peer = PeerID(publicKey: "expiring-service")
        let start = ContinuousClock.now
        let expired = service.issue(for: peer, nonce: testNonce(1), at: start)
        #expect(service.outstandingCount == 1)

        let expiry = start.advanced(by: .seconds(5))
        let expiredAccepted = service.verify(expired, solution: Data(), peer: peer, at: expiry)
        #expect(!expiredAccepted)
        #expect(service.outstandingCount == 0)

        let fresh = service.issue(for: peer, nonce: testNonce(2), at: expiry)
        let freshAccepted = service.verify(fresh, solution: Data(), peer: peer, at: expiry)
        let replayAccepted = service.verify(fresh, solution: Data(), peer: peer, at: expiry)
        #expect(freshAccepted)
        #expect(!replayAccepted)
        #expect(service.outstandingCount == 0)
    }

    @Test("Outstanding challenges evict deterministically and restart fresh")
    func boundedOutstandingChallenges() {
        let config = TallyConfig(
            challengeDifficulty: 0,
            challengeExpiration: .seconds(60),
            maxPeers: 1
        )
        var service = ChallengeService(config: config)
        let peers = (0...config.outstandingChallengeCapacity).map {
            PeerID(publicKey: "challenge-capacity-peer-\($0)")
        }
        let start = ContinuousClock.now
        var challenges: [Challenge] = []

        for index in 0..<config.outstandingChallengeCapacity {
            challenges.append(service.issue(
                for: peers[index],
                nonce: testNonce(UInt64(index)),
                at: start.advanced(by: .milliseconds(index))
            ))
        }
        challenges[0] = service.issue(
            for: peers[0],
            nonce: challenges[0].nonce,
            at: start.advanced(by: .milliseconds(10))
        )
        _ = service.issue(
            for: peers.last!,
            nonce: testNonce(UInt64(config.outstandingChallengeCapacity)),
            at: start.advanced(by: .milliseconds(11))
        )

        let now = start.advanced(by: .milliseconds(12))
        #expect(service.outstandingCount == config.outstandingChallengeCapacity)
        let evictedAccepted = service.verify(
            challenges[1],
            solution: Data(),
            peer: peers[1],
            at: now
        )
        let retainedAccepted = service.verify(
            challenges[0],
            solution: Data(),
            peer: peers[0],
            at: now
        )
        #expect(!evictedAccepted)
        #expect(retainedAccepted)

        let replacement = service.issue(for: peers[1], nonce: testNonce(100), at: now)
        let replacementAccepted = service.verify(
            replacement,
            solution: Data(),
            peer: peers[1],
            at: now
        )
        #expect(replacementAccepted)
    }
}
