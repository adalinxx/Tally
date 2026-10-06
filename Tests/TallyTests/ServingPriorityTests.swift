import Foundation
import Testing
@testable import Tally

@Suite("Serving priority")
struct ServingPriorityTests {
    @Test("a peer with no verified-content history has zero priority")
    func unknownPeerIsZero() {
        let tally = Tally()
        #expect(tally.servingPriority(for: PeerID(publicKey: "stranger")) == 0)
    }

    @Test("only verified, requested content raises priority; raw traffic does not")
    func onlyUsefulContentCounts() {
        let tally = Tally()
        let spammer = PeerID(publicKey: "spammer")
        let server = PeerID(publicKey: "server")
        tally.recordReceived(peer: spammer, bytes: 1_000_000)
        tally.recordSent(peer: spammer, bytes: 1_000_000)
        tally.recordUsefulReceived(peer: server, bytes: 10)

        #expect(tally.servingPriority(for: spammer) == 0)
        #expect(tally.servingPriority(for: server) > 0)
        #expect(tally.metrics.totalUsefulBytesReceived == 10)
        #expect(tally.metrics.totalBytesReceived == 1_000_000)
    }

    @Test("priority orders peers by how much verified content they served")
    func orderedByUsefulBytes() {
        let tally = Tally()
        let small = PeerID(publicKey: "small")
        let large = PeerID(publicKey: "large")
        tally.recordUsefulReceived(peer: small, bytes: 100)
        tally.recordUsefulReceived(peer: large, bytes: 10_000)
        #expect(tally.servingPriority(for: large) > tally.servingPriority(for: small))
    }

    @Test("zero and negative credits are ignored")
    func nonPositiveIgnored() {
        let tally = Tally()
        let peer = PeerID(publicKey: "peer")
        tally.recordUsefulReceived(peer: peer, bytes: 0)
        tally.recordUsefulReceived(peer: peer, bytes: -5)
        #expect(tally.servingPriority(for: peer) == 0)
        #expect(tally.metrics.totalUsefulBytesReceived == 0)
    }

    @Test("protocol violations divide priority")
    func violationsDemote() {
        let start = ContinuousClock.now
        var state = Tally.State(config: TallyConfig(decayHalfLife: 60))
        let peer = PeerID(publicKey: "peer")
        state.recordUseful(peer: peer, bytes: 1_000, at: start, halfLife: 60)
        #expect(abs(state.servingPriority(for: peer, at: start, halfLife: 60) - 1_000) < 0.000_001)
        state.mutateEvidence(for: peer, at: start) {
            $0.recordProtocolViolation(at: start, halfLife: 60)
        }
        #expect(abs(state.servingPriority(for: peer, at: start, halfLife: 60) - 500) < 0.000_001)
    }

    @Test("credit decays on the evidence half-life")
    func creditDecays() {
        let start = ContinuousClock.now
        var credit = UsefulCredit(now: start)
        credit.record(1_000, at: start, halfLife: 10)
        #expect(abs(credit.value(at: start.advanced(by: .seconds(10)), halfLife: 10) - 500) < 0.000_001)
        credit.record(500, at: start.advanced(by: .seconds(10)), halfLife: 10)
        #expect(abs(credit.value(at: start.advanced(by: .seconds(10)), halfLife: 10) - 1_000) < 0.000_001)
    }

    @Test("asking for a peer's priority changes no record")
    func priorityReadIsPure() {
        let start = ContinuousClock.now
        var state = Tally.State(config: TallyConfig(decayHalfLife: 60))
        let peer = PeerID(publicKey: "peer")
        state.recordUseful(peer: peer, bytes: 1_000, at: start, halfLife: 60)
        let later = start.advanced(by: .seconds(60))
        let first = state.servingPriority(for: peer, at: later, halfLife: 60)
        let second = state.servingPriority(for: peer, at: later, halfLife: 60)
        #expect(first == second)
        #expect(state.credit.value(forKey: peer)?.lastUpdate == start)
    }

    @Test("at capacity, the credit worth least now is dropped, however large it once was")
    func creditEvictionUsesDecayedValue() {
        let start = ContinuousClock.now
        let halfLife = 60.0
        // Capacity = maxPeers × 4 = 4 credit records.
        var state = Tally.State(config: TallyConfig(decayHalfLife: halfLife, maxPeers: 1))
        let stale = PeerID(publicKey: "stale")
        state.recordUseful(peer: stale, bytes: 1_000_000, at: start, halfLife: halfLife)
        let later = start.advanced(by: .seconds(3_600))
        let fresh = (0..<3).map { PeerID(publicKey: "fresh-\($0)") }
        for peer in fresh { state.recordUseful(peer: peer, bytes: 10_000, at: later, halfLife: halfLife) }
        let newcomer = PeerID(publicKey: "newcomer")
        state.recordUseful(peer: newcomer, bytes: 10_000, at: later, halfLife: halfLife)

        #expect(state.credit.count == 4)
        #expect(state.credit.value(forKey: stale) == nil)
        for peer in fresh + [newcomer] { #expect(state.credit.value(forKey: peer) != nil) }
    }

    @Test("a flood of new identities cannot erase a helpful peer's credit")
    func floodKeepsCredit() {
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        let helpful = PeerID(publicKey: "helpful")
        tally.recordUsefulReceived(peer: helpful, bytes: 1_000)
        for index in 0..<50 {
            let peer = PeerID(publicKey: "flood-\(index)")
            tally.recordReceived(peer: peer, bytes: 1)
            tally.recordProtocolViolation(peer: peer)
        }
        #expect(tally.servingPriority(for: helpful) > 0)
    }

    @Test("credit never decides whose admission evidence survives")
    func creditDoesNotAffectAdmissionEviction() {
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        // Every credit slot is held.
        for index in 0..<4 {
            tally.recordUsefulReceived(peer: PeerID(publicKey: "credited-\(index)"), bytes: 100)
        }
        // Admission evidence stays least-recently-used: five newcomers, the
        // oldest is evicted, the newest four keep their evidence.
        let newcomers = (0..<5).map { PeerID(publicKey: "newcomer-\($0)") }
        for peer in newcomers { tally.recordReceived(peer: peer, bytes: 100) }
        #expect(tally.admissionScore(for: newcomers[0]) == 0)
        for peer in newcomers.dropFirst() { #expect(tally.admissionScore(for: peer) > 0) }
    }

    @Test("without credit, admission eviction is unchanged least-recently-used")
    func admissionEvictionIsLRU() {
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        let peers = (0..<5).map { PeerID(publicKey: "peer-\($0)") }
        for peer in peers { tally.recordReceived(peer: peer, bytes: 100) }
        #expect(tally.peerCount == 4)
        #expect(tally.admissionScore(for: peers[0]) == 0)
        for peer in peers.dropFirst() { #expect(tally.admissionScore(for: peer) > 0) }
    }

    @Test("resetting a peer clears its credit")
    func resetClearsCredit() {
        let tally = Tally()
        let peer = PeerID(publicKey: "peer")
        tally.recordUsefulReceived(peer: peer, bytes: 100)
        tally.resetPeer(peer)
        #expect(tally.servingPriority(for: peer) == 0)
    }
}
