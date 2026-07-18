import Testing
import Foundation
@testable import Tally

@Suite("CreditLine")
struct CreditLineTests {

    @Test("Available capacity clamps thresholds wider than Int64")
    func testAvailableCapacityClampsWideThreshold() {
        var line = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: UInt64(Int64.max) + 100
        )

        #expect(line.availableCapacity == Int64.max)
        #expect(!line.needsSettlement)
        #expect(line.debtPressure == 0)

        line.adjustBalance(by: Int64.max)
        #expect(line.availableCapacity == 0)
        #expect(line.needsSettlement)
        #expect(line.debtPressure == 1)

        line.recordSettlement()
        #expect(line.threshold == UInt64.max)
        #expect(line.balance == 0)
    }

    @Test("Balance saturates in both directions instead of trapping")
    func testCreditLineBalanceSaturates() {
        let local = PeerID(publicKey: "local")
        let remote = PeerID(publicKey: "remote")
        var positive = CreditLine(
            peerA: local,
            peerB: remote,
            threshold: 1
        )
        positive.adjustBalance(by: .max)
        positive.adjustBalance(by: 1)
        #expect(positive.balance == .max)

        var negative = CreditLine(
            peerA: local,
            peerB: remote,
            threshold: 1
        )
        negative.adjustBalance(by: .min)
        negative.adjustBalance(by: -1)
        #expect(negative.balance == .min)
    }

    @Test("Successful settlement never lowers any sampled threshold")
    func settlementThresholdProperty() {
        for initial in UInt64(0)...256 {
            var line = CreditLine(
                peerA: PeerID(publicKey: "local"),
                peerB: PeerID(publicKey: "remote"),
                threshold: initial
            )
            for settlement in 0..<64 {
                line.adjustBalance(by: Int64(settlement + 1))
                let previous = line.threshold
                line.recordSettlement()
                #expect(line.balance == 0, "initial \(initial), settlement \(settlement)")
                #expect(line.threshold >= previous, "initial \(initial), settlement \(settlement)")
            }
        }

        var maximum = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: .max
        )
        maximum.recordSettlement()
        #expect(maximum.threshold == .max)
    }

    @Test("Successful settlement recovers a zero threshold")
    func testSuccessfulSettlementRecoversZeroThreshold() {
        var line = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: 1
        )

        line.recordMissedSettlement()
        #expect(line.threshold == 0)
        #expect(line.needsSettlement)

        line.recordSettlement()
        #expect(line.threshold == 2)
    }

    @Test("Successful settlement does not shrink a nondivisible threshold")
    func testSuccessfulSettlementRoundsThresholdUp() {
        var line = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: 3
        )

        line.recordSettlement()
        #expect(line.threshold == 6)
        line.recordMissedSettlement()
        #expect(line.threshold == 3)
        line.recordSettlement()
        #expect(line.threshold == 4)
        line.recordMissedSettlement()
        #expect(line.threshold == 2)
        line.recordMissedSettlement()
        #expect(line.threshold == 1)
        line.recordSettlement()
        #expect(line.threshold == 3)
    }

    @Test("Initial threshold saturates at UInt64 max")
    func testInitialThresholdSaturates() {
        #expect(CreditLine.initialThreshold(baseTrust: 1, multiplier: .max) == .max)
        #expect(CreditLine.initialThreshold(baseTrust: .nan, multiplier: .max) == 0)
    }

    @Test("Partial settlement moves toward zero without crossing")
    func partialSettlementProperty() {
        let balances: [Int64] = [.min, -100, -1, 0, 1, 100, .max]
        let workValues: [Int64] = [1, 2, 100, .max]

        for balance in balances {
            for work in workValues {
                var line = CreditLine(
                    peerA: PeerID(publicKey: "local"),
                    peerB: PeerID(publicKey: "remote"),
                    threshold: 100
                )
                line.adjustBalance(by: balance)
                let sequence = line.sequence
                line.recordPartialSettlement(workValue: work)

                #expect(line.balance.magnitude <= balance.magnitude)
                #expect(balance >= 0 ? line.balance >= 0 : line.balance <= 0)
                #expect(line.sequence == sequence + 1)
            }
        }
    }

    @Test("Seeded credit-line operations preserve accounting invariants")
    func seededCreditLineOperations() {
        var random = SeededGenerator(defaultSeed: 0xc4ed_17a1)
        let seed = random.state
        var line = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: random.next() % 1_000
        )
        let amounts: [Int64] = [.min, -1_000, -1, 0, 1, 1_000, .max]

        for step in 0..<1_000 {
            switch random.index(upperBound: 4) {
            case 0:
                let amount = amounts[random.index(upperBound: amounts.count)]
                let previous = line.balance
                let sequence = line.sequence
                let (sum, overflow) = previous.addingReportingOverflow(amount)
                let expected = overflow ? (amount >= 0 ? Int64.max : Int64.min) : sum
                line.adjustBalance(by: amount)
                #expect(line.balance == expected, "seed \(seed), step \(step)")
                #expect(line.sequence == sequence + 1, "seed \(seed), step \(step)")

            case 1:
                let work = amounts[random.index(upperBound: amounts.count)]
                let previous = line.balance
                let sequence = line.sequence
                line.recordPartialSettlement(workValue: work)
                if work > 0 {
                    #expect(line.balance.magnitude <= previous.magnitude, "seed \(seed), step \(step)")
                    #expect(previous >= 0 ? line.balance >= 0 : line.balance <= 0, "seed \(seed), step \(step)")
                    #expect(line.sequence == sequence + 1, "seed \(seed), step \(step)")
                } else {
                    #expect(line.balance == previous, "seed \(seed), step \(step)")
                    #expect(line.sequence == sequence, "seed \(seed), step \(step)")
                }

            case 2:
                let threshold = line.threshold
                let settlements = line.successfulSettlements
                line.recordSettlement()
                #expect(line.balance == 0, "seed \(seed), step \(step)")
                #expect(line.threshold >= threshold, "seed \(seed), step \(step)")
                #expect(line.successfulSettlements == settlements + 1, "seed \(seed), step \(step)")

            default:
                let threshold = line.threshold
                line.recordMissedSettlement()
                #expect(line.threshold == threshold / 2, "seed \(seed), step \(step)")
            }

            #expect(line.debtPressure.isFinite, "seed \(seed), step \(step)")
            #expect((0...1).contains(line.debtPressure), "seed \(seed), step \(step)")
        }
    }

    @Test("Relay accounting rejects non-positive amounts")
    func testLedgerRejectsNonPositiveAmounts() async {
        let local = PeerID(publicKey: "local")
        let remote = PeerID(publicKey: "remote")
        let ledger = CreditLineLedger(localID: local)
        _ = await ledger.establish(with: remote)

        #expect(!(await ledger.chargeForRelay(peer: remote, amount: .min)))
        await ledger.earnFromRelay(peer: remote, amount: .min)
        #expect(await ledger.balance(with: remote) == 0)
    }

    @Test("Ledger canonicalizes key work on the public establish path")
    func ledgerCanonicalKeyWork() async {
        let raw = "0000000000000000000000000000000000000000000000000000000000000059"
        let malformed = "ed01" + "0000000000000000000000000000000000000000000000000000000000004afg"
        let ledger = CreditLineLedger(localID: PeerID(publicKey: "local"))

        let rawLine = await ledger.establish(with: PeerID(publicKey: raw))
        let multikeyLine = await ledger.establish(with: PeerID(publicKey: "ed01" + raw))
        let malformedLine = await ledger.establish(with: PeerID(publicKey: malformed))

        #expect(rawLine.threshold == multikeyLine.threshold)
        #expect(rawLine.threshold > 1)
        #expect(malformedLine.threshold == 1)
    }

    @Test("Ledger facade preserves peer isolation, removal, and re-establishment")
    func ledgerFacadeStateMachine() async throws {
        let local = PeerID(publicKey: "local")
        let firstPeer = PeerID(publicKey: "first")
        let secondPeer = PeerID(publicKey: "second")
        let missingPeer = PeerID(publicKey: "missing")
        let ledger = CreditLineLedger(localID: local)

        let first = await ledger.establish(with: firstPeer)
        let second = await ledger.establish(with: secondPeer)
        #expect(await ledger.establish(with: firstPeer).sequence == first.sequence)
        #expect(await ledger.creditLine(for: firstPeer)?.peerA == local)
        #expect(await ledger.creditLine(for: firstPeer)?.peerB == firstPeer)
        #expect(await ledger.allLines.count == 2)
        #expect(await ledger.balance(with: missingPeer) == 0)
        #expect(await ledger.threshold(for: missingPeer) == 0)
        #expect(!(await ledger.needsSettlement(peer: missingPeer)))
        #expect(await ledger.debtPressure(for: missingPeer) == 0)

        let firstThreshold = try #require(Int64(exactly: first.threshold))
        #expect(await ledger.chargeForRelay(peer: firstPeer, amount: firstThreshold))
        #expect(await ledger.needsSettlement(peer: firstPeer))
        #expect(await ledger.debtPressure(for: firstPeer) == 1)
        await ledger.recordPartialSettlement(peer: firstPeer, workValue: max(firstThreshold / 2, 1))
        #expect(await ledger.balance(with: firstPeer) <= 0)
        await ledger.earnFromRelay(peer: firstPeer, amount: 1)
        #expect(await ledger.balance(with: secondPeer) == second.balance)

        let thresholdBeforeMiss = await ledger.threshold(for: firstPeer)
        await ledger.recordMissedSettlement(peer: firstPeer)
        #expect(await ledger.threshold(for: firstPeer) == thresholdBeforeMiss / 2)
        let thresholdBeforeSuccess = await ledger.threshold(for: firstPeer)
        await ledger.recordSettlement(peer: firstPeer)
        #expect(await ledger.balance(with: firstPeer) == 0)
        #expect(await ledger.threshold(for: firstPeer) >= thresholdBeforeSuccess)

        #expect(!(await ledger.chargeForRelay(peer: missingPeer, amount: 1)))
        await ledger.earnFromRelay(peer: missingPeer, amount: 1)
        await ledger.recordPartialSettlement(peer: missingPeer, workValue: 1)
        await ledger.recordMissedSettlement(peer: missingPeer)
        await ledger.recordSettlement(peer: missingPeer)

        let removed = try #require(await ledger.removeLine(for: firstPeer))
        #expect(removed.balance == 0)
        #expect(await ledger.creditLine(for: firstPeer) == nil)
        #expect(await ledger.allLines.count == 1)
        let reestablished = await ledger.establish(with: firstPeer)
        #expect(reestablished.balance == 0)
        #expect(reestablished.sequence == 0)
        #expect(reestablished.successfulSettlements == 0)
        #expect(await ledger.allLines.count == 2)
    }

    @Test("Credit accounting cannot mutate admission state")
    func creditAdmissionIsolation() async {
        let peer = PeerID(publicKey: "isolated")
        let tally = Tally(config: TallyConfig(
            decayHalfLife: Double.greatestFiniteMagnitude,
            exchangeBaseline: 100
        ))
        tally.recordReceived(peer: peer, bytes: 100)
        let score = tally.admissionScore(for: peer)
        let metrics = tally.metrics
        let pressure = tally.ratePressure()

        let ledger = CreditLineLedger(localID: PeerID(publicKey: "local"))
        _ = await ledger.establish(with: peer)
        _ = await ledger.chargeForRelay(peer: peer, amount: 10)
        await ledger.recordMissedSettlement(peer: peer)
        await ledger.recordSettlement(peer: peer)

        #expect(abs(tally.admissionScore(for: peer) - score) < 0.000_000_001)
        #expect(tally.metrics == metrics)
        #expect(tally.ratePressure() == pressure)
        #expect(tally.peerCount == 1)
    }
}
