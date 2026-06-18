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
    }
}
