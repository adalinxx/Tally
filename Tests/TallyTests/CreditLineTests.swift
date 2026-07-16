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

    @Test("Balance saturates instead of trapping")
    func testCreditLineBalanceSaturates() {
        var line = CreditLine(
            peerA: PeerID(publicKey: "local"),
            peerB: PeerID(publicKey: "remote"),
            threshold: 1
        )
        line.adjustBalance(by: .max)
        line.adjustBalance(by: 1)
        #expect(line.balance == .max)
    }

    @Test("Initial threshold saturates at UInt64 max")
    func testInitialThresholdSaturates() {
        #expect(CreditLine.initialThreshold(baseTrust: 1, multiplier: .max) == .max)
        #expect(CreditLine.initialThreshold(baseTrust: .nan, multiplier: .max) == 0)
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
}
