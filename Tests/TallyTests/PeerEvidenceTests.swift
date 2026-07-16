import Foundation
import Testing
@testable import Tally

@Suite("PeerEvidence")
struct PeerEvidenceTests {
    @Test("Admission score follows the four-signal formula")
    func admissionScoreFormula() {
        let now = ContinuousClock.now
        let peer = PeerID(publicKey: "peer-0")
        let config = TallyConfig(
            decayHalfLife: 10,
            hardnessBaseline: 10,
            exchangeBaseline: 100,
            powBaseline: 16
        )
        var evidence = PeerEvidence(now: now)
        evidence.recordSent(25, at: now, halfLife: 10)
        evidence.recordReceived(75, at: now, halfLife: 10)
        evidence.recordProtocolViolation(at: now, halfLife: 10)
        evidence.recordChallengeWork(5, at: now, halfLife: 10)

        let score = evidence.admissionScore(for: peer, at: now, config: config)
        let expected = (0.50 * (76.0 / 101.0) + 0.25 * 0.5) / 2

        #expect(abs(score - expected) < 0.000_001)
    }

    @Test("Every mutation decays every evidence field")
    func allMutationsDecayAllEvidence() {
        let start = ContinuousClock.now
        let later = start.advanced(by: .seconds(10))
        var baseline = PeerEvidence(now: start)
        baseline.recordSent(8, at: start, halfLife: 10)
        baseline.recordReceived(8, at: start, halfLife: 10)
        baseline.recordProtocolViolation(at: start, halfLife: 10)
        baseline.recordChallengeWork(8, at: start, halfLife: 10)

        var sent = baseline
        sent.recordSent(2, at: later, halfLife: 10)
        #expect(abs(sent.bytesSent - 6) < 0.000_001)
        #expect(abs(sent.bytesReceived - 4) < 0.000_001)
        #expect(abs(sent.protocolViolations - 0.5) < 0.000_001)
        #expect(abs(sent.challengeWork - 4) < 0.000_001)
        #expect(sent.lastUpdate == later)

        var received = baseline
        received.recordReceived(2, at: later, halfLife: 10)
        #expect(abs(received.bytesSent - 4) < 0.000_001)
        #expect(abs(received.bytesReceived - 6) < 0.000_001)
        #expect(abs(received.protocolViolations - 0.5) < 0.000_001)
        #expect(abs(received.challengeWork - 4) < 0.000_001)
        #expect(received.lastUpdate == later)

        var violated = baseline
        violated.recordProtocolViolation(at: later, halfLife: 10)
        #expect(abs(violated.bytesSent - 4) < 0.000_001)
        #expect(abs(violated.bytesReceived - 4) < 0.000_001)
        #expect(abs(violated.protocolViolations - 1.5) < 0.000_001)
        #expect(abs(violated.challengeWork - 4) < 0.000_001)
        #expect(violated.lastUpdate == later)

        var challenged = baseline
        challenged.recordChallengeWork(2, at: later, halfLife: 10)
        #expect(abs(challenged.bytesSent - 4) < 0.000_001)
        #expect(abs(challenged.bytesReceived - 4) < 0.000_001)
        #expect(abs(challenged.protocolViolations - 0.5) < 0.000_001)
        #expect(abs(challenged.challengeWork - 6) < 0.000_001)
        #expect(challenged.lastUpdate == later)
    }

    @Test("Score observation decays every evidence field")
    func scoreObservationDecaysAllEvidence() {
        let start = ContinuousClock.now
        let later = start.advanced(by: .seconds(10))
        let config = TallyConfig(decayHalfLife: 10)
        var evidence = PeerEvidence(now: start)
        evidence.recordSent(8, at: start, halfLife: 10)
        evidence.recordReceived(8, at: start, halfLife: 10)
        evidence.recordProtocolViolation(at: start, halfLife: 10)
        evidence.recordChallengeWork(8, at: start, halfLife: 10)

        _ = evidence.admissionScore(
            for: PeerID(publicKey: "score-decay"),
            at: later,
            config: config
        )

        #expect(abs(evidence.bytesSent - 4) < 0.000_001)
        #expect(abs(evidence.bytesReceived - 4) < 0.000_001)
        #expect(abs(evidence.protocolViolations - 0.5) < 0.000_001)
        #expect(abs(evidence.challengeWork - 4) < 0.000_001)
        #expect(evidence.lastUpdate == later)
    }
}
