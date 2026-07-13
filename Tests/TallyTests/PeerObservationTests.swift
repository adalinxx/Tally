import XCTest
@testable import Tally

final class PeerObservationTests: XCTestCase {
    private let peer = PeerID(publicKey: String(repeating: "ab", count: 32))

    func testLocalFailuresDoNotCreateOrPenalizePeerLedger() {
        let tally = Tally()

        tally.record(.localFailure(.cancelled), for: peer)
        tally.record(.localFailure(.overloaded), for: peer)
        tally.record(.localFailure(.storageUnavailable), for: peer)
        tally.record(.localFailure(.validationUnavailable), for: peer)

        XCTAssertNil(tally.peerLedger(for: peer))
        XCTAssertEqual(tally.peerCount, 0)
    }

    func testRemoteFailureIsAttributedToPeer() throws {
        let tally = Tally()

        tally.record(.remoteFailure(.contentAddressMismatch), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.failureCount.value, 1)
        XCTAssertEqual(ledger.successCount.value, 0)
    }

    func testSuccessfulResponseRecordsOutcomeAndLatency() throws {
        let tally = Tally()

        tally.record(.responseSucceeded(latencyMicroseconds: 2_500), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.successCount.value, 1)
        XCTAssertEqual(ledger.failureCount.value, 0)
        XCTAssertEqual(ledger.latencyEWMA.count, 1)
        XCTAssertEqual(ledger.latencyEWMA.value, 2_500)
    }

    func testByteObservationsPreserveExistingAccounting() throws {
        let tally = Tally()

        tally.record(.bytesReceived(4_096), for: peer)
        tally.record(.bytesSent(1_024), for: peer)
        tally.record(.bytesReceived(0), for: peer)
        tally.record(.bytesSent(-1), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.bytesReceived.value, 4_096)
        XCTAssertEqual(ledger.bytesSent.value, 1_024)
    }
}
