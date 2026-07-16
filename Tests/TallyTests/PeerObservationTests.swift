import XCTest
@testable import Tally

final class PeerObservationTests: XCTestCase {
    private let peer = PeerID(publicKey: String(repeating: "ab", count: 32))

    func testOperationalFailuresDoNotCreateOrPenalizePeerLedger() {
        let tally = Tally()

        tally.record(.operationalFailure(.cancelled), for: peer)
        tally.record(.operationalFailure(.overloaded), for: peer)
        tally.record(.operationalFailure(.storageUnavailable), for: peer)
        tally.record(.operationalFailure(.validationUnavailable), for: peer)
        tally.record(.operationalFailure(.ambiguousTimeout), for: peer)

        XCTAssertNil(tally.peerLedger(for: peer))
        XCTAssertEqual(tally.peerCount, 0)
    }

    func testFailureCategoriesRemainDistinct() throws {
        let tally = Tally()

        tally.record(.protocolFailure(.contentAddressMismatch), for: peer)
        tally.record(.serviceFailure(.advertisedContentUnavailable), for: peer)
        tally.record(.routeFailure(.attributedTimeout), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.failureCount.value, 3)
        XCTAssertEqual(ledger.protocolFailureCount.value, 1)
        XCTAssertEqual(ledger.serviceFailureCount.value, 1)
        XCTAssertEqual(ledger.routeFailureCount.value, 1)
        XCTAssertEqual(ledger.successCount.value, 0)
        XCTAssertEqual(tally.quality(.protocolCorrectness, for: peer), 0.5, accuracy: 0.001)
        XCTAssertEqual(tally.quality(.serviceReliability, for: peer), 0, accuracy: 0.001)
        XCTAssertEqual(tally.quality(.routeReliability, for: peer), 0, accuracy: 0.001)
    }

    func testSuccessfulServiceRecordsOutcomeAndLatency() throws {
        let tally = Tally()

        tally.record(.serviceSucceeded(latencyMicroseconds: 2_500), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.successCount.value, 1)
        XCTAssertEqual(ledger.serviceSuccessCount.value, 1)
        XCTAssertEqual(ledger.failureCount.value, 0)
        XCTAssertEqual(ledger.latencyEWMA.count, 1)
        XCTAssertEqual(ledger.latencyEWMA.value, 2_500)
    }

    func testUnavailableAdvertisementPenalizesOnlyItsAdvertiser() throws {
        let advertiser = peer
        let unrelated = PeerID(publicKey: String(repeating: "cd", count: 32))
        let tally = Tally()

        tally.record(.serviceFailure(.advertisedContentUnavailable), for: advertiser)

        XCTAssertEqual(try XCTUnwrap(tally.peerLedger(for: advertiser)).serviceFailureCount.value, 1)
        XCTAssertNil(tally.peerLedger(for: unrelated))
    }

    func testInvalidLatencySamplesAreIgnored() throws {
        let tally = Tally()

        tally.record(.serviceSucceeded(latencyMicroseconds: .nan), for: peer)
        tally.record(.serviceSucceeded(latencyMicroseconds: .infinity), for: peer)
        tally.record(.serviceSucceeded(latencyMicroseconds: -1), for: peer)

        let ledger = try XCTUnwrap(tally.peerLedger(for: peer))
        XCTAssertEqual(ledger.serviceSuccessCount.value, 3)
        XCTAssertEqual(ledger.latencyEWMA.count, 0)
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

    func testUnknownPeerQualityIsNeutral() {
        let tally = Tally()

        XCTAssertEqual(tally.quality(.protocolCorrectness, for: peer), 0.5)
        XCTAssertEqual(tally.quality(.serviceReliability, for: peer), 0.5)
        XCTAssertEqual(tally.quality(.routeReliability, for: peer), 0.5)
    }
}
