import Testing
import Foundation
@testable import Tally

@Suite("PeerLedger")
struct PeerLedgerTests {

    @Test("Debt ratio is zero when nothing sent")
    func testDebtRatioZero() {
        let ledger = PeerLedger(now: .now)
        #expect(ledger.debtRatio == 0)
    }

    @Test("Debt ratio increases with bytes sent")
    func testDebtRatioIncreases() {
        var ledger = PeerLedger(now: .now)
        ledger.bytesSent.add(1000)
        #expect(ledger.debtRatio == 1000.0)
    }

    @Test("Bytes received reduces debt ratio")
    func testBytesReceivedReducesDebt() {
        var ledger = PeerLedger(now: .now)
        ledger.bytesSent.add(1000)
        ledger.bytesReceived.add(999)
        #expect(ledger.debtRatio == 1.0)
    }

    @Test("Reciprocity is 1.0 when nothing sent")
    func testReciprocityFull() {
        let ledger = PeerLedger(now: .now)
        #expect(ledger.reciprocity == 1.0)
    }

    @Test("Reciprocity decreases with debt")
    func testReciprocityDecreases() {
        var ledger = PeerLedger(now: .now)
        ledger.bytesSent.add(1000)
        #expect(ledger.reciprocity < 0.01)
    }

    @Test("Success rate defaults to 0.5 with no data")
    func testSuccessRateDefault() {
        let ledger = PeerLedger(now: .now)
        #expect(ledger.successRate == 0.5)
    }

    @Test("Success rate reflects outcomes")
    func testSuccessRate() {
        var ledger = PeerLedger(now: .now)
        ledger.successCount.add(9)
        ledger.failureCount.add(1)
        #expect(ledger.successRate == 0.9)
    }

    @Test("Failure penalty is squared")
    func testFailurePenaltySquared() {
        var ledger = PeerLedger(now: .now)
        ledger.successCount.add(5)
        ledger.failureCount.add(5)
        #expect(ledger.failurePenalty == 0.25)

        var worse = PeerLedger(now: .now)
        worse.successCount.add(2)
        worse.failureCount.add(8)
        #expect(worse.failurePenalty > 0.63 && worse.failurePenalty < 0.65)
    }

    @Test("Reputation is composite of all factors")
    func testReputationComposite() {
        var ledger = PeerLedger(now: .now)
        ledger.bytesReceived.add(1000)
        ledger.bytesSent.add(100)
        ledger.successCount.add(10)
        ledger.latencyEWMA.record(50_000)
        ledger.challengeHardness.add(5)
        let rep = ledger.reputation()
        #expect(rep > 0.5)
        #expect(rep <= 1.0)
    }

    @Test("Challenges boost reputation")
    func testChallengesBoost() {
        var withChallenges = PeerLedger(now: .now)
        withChallenges.challengeHardness.add(10)

        var without = PeerLedger(now: .now)

        #expect(withChallenges.reputation() > without.reputation())
    }

    @Test("Low latency improves reputation")
    func testLatencyImprovesRep() {
        var fast = PeerLedger(now: .now)
        fast.latencyEWMA.record(1_000)

        var slow = PeerLedger(now: .now)
        slow.latencyEWMA.record(500_000)

        #expect(fast.reputation() > slow.reputation())
    }

    @Test("EWMA weights recent samples higher")
    func testEWMARecency() {
        var ewma = EWMA(alpha: 0.5)
        ewma.record(100)
        ewma.record(100)
        ewma.record(100)
        ewma.record(1000)
        #expect(ewma.value > 300)
    }

    @Test("Decaying counter halves after one half-life")
    func testDecayingCounter() {
        let past = ContinuousClock.now - .seconds(3600)
        var counter = DecayingCounter(lastDecay: past)
        counter.value = 1000
        counter.decay(to: .now, halfLife: 3600)
        #expect(counter.value > 490 && counter.value < 510)
    }

    @Test("Custom weights")
    func testCustomWeights() {
        var ledger1 = PeerLedger(now: .now)
        ledger1.bytesSent.add(200_000)
        ledger1.challengeHardness.add(160)
        var ledger2 = ledger1
        let challengeHeavy = ReputationWeights(reciprocity: 0, latency: 0, successRate: 0, challenges: 1.0)
        let noChallenges = ReputationWeights(reciprocity: 1.0, latency: 0, successRate: 0, challenges: 0)
        #expect(ledger1.reputation(weights: challengeHeavy, latencyBaseline: 100_000) > ledger2.reputation(weights: noChallenges, latencyBaseline: 100_000))
    }

    @Test("Failure penalty reduces effective success score")
    func testFailurePenaltyReducesReputation() {
        var clean = PeerLedger(now: .now)
        clean.successCount.add(10)

        var dirty = PeerLedger(now: .now)
        dirty.successCount.add(10)
        dirty.failureCount.add(10)

        let weights = ReputationWeights(reciprocity: 0, latency: 0, successRate: 1.0, challenges: 0)
        #expect(clean.reputation(weights: weights, latencyBaseline: 100_000) > dirty.reputation(weights: weights, latencyBaseline: 100_000))
    }

    @Test("Behavioral counters decay reputation over time")
    func testBehavioralCountersDecayReputation() {
        let t0 = ContinuousClock.now
        var ledger = PeerLedger(now: t0)
        ledger.successCount.add(1)
        let peer = PeerID(publicKey: "decay-success")
        let config = TallyConfig(
            weights: ReputationWeights(reciprocity: 0, latency: 0, successRate: 1, challenges: 0, pow: 0),
            decayHalfLife: 1
        )
        let scorer = ReputationScorer(config: config)

        let initial = scorer.score(&ledger, peer: peer, at: t0)
        let decayed = scorer.score(&ledger, peer: peer, at: t0.advanced(by: .seconds(1)))

        #expect(initial == 1)
        #expect(decayed < initial)
        #expect(ledger.successCount.value < 1)
    }

    @Test("POW scales only after exchange")
    func testPowScalesAfterExchange() {
        let weights = ReputationWeights(reciprocity: 0, latency: 0, successRate: 0, challenges: 0, pow: 1.0)
        var high = PeerLedger(now: .now)
        var low = PeerLedger(now: .now)
        high.bytesReceived.add(100_000)
        low.bytesReceived.add(100_000)

        let highRep = high.reputation(weights: weights, peerPowBits: 12, powBaseline: 16)
        let lowRep = low.reputation(weights: weights, peerPowBits: 2, powBaseline: 16)
        #expect(highRep > lowRep)
    }

    @Test("POW bonus caps at weight after exchange")
    func testPowCapsAtBaseline() {
        let weights = ReputationWeights(reciprocity: 0, latency: 0, successRate: 0, challenges: 0, pow: 0.1)
        var ledger = PeerLedger(now: .now)
        ledger.bytesReceived.add(100_000)
        let rep = ledger.reputation(weights: weights, peerPowBits: 32, powBaseline: 16)
        #expect(rep == 0.1)
    }

    @Test("Zero POW bits gives zero POW floor")
    func testZeroPowBits() {
        var ledger = PeerLedger(now: .now)
        let rep = ledger.reputation(peerPowBits: 0, powBaseline: 16)
        #expect(rep >= 0)
    }

    @Test("POW bonus adds to behavioral reputation")
    func testPowBonusIsAdditive() {
        let weights = ReputationWeights(reciprocity: 0, latency: 0, successRate: 0.5, challenges: 0, pow: 0.1)
        var ledger = PeerLedger(now: .now)
        ledger.bytesReceived.add(100_000)
        ledger.successCount.add(10)
        let withPow = ledger.reputation(weights: weights, peerPowBits: 16, powBaseline: 16)
        ledger.reputationStale = true
        let withoutPow = ledger.reputation(weights: weights, peerPowBits: 0, powBaseline: 16)
        #expect(withPow > withoutPow)
        #expect(withPow - withoutPow > 0.09 && withPow - withoutPow < 0.11)
    }
}
