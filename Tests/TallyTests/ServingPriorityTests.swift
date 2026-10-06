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
        #expect(tally.peerCount == 0)
    }

    @Test("protocol violations divide priority, like the admission score")
    func violationsDemote() {
        let start = ContinuousClock.now
        var evidence = PeerEvidence(now: start)
        evidence.recordUsefulReceived(1_000, at: start, halfLife: 60)
        let clean = evidence.servingPriority(at: start, halfLife: 60)
        evidence.recordProtocolViolation(at: start, halfLife: 60)
        let violated = evidence.servingPriority(at: start, halfLife: 60)
        #expect(abs(clean - 1_000) < 0.000_001)
        #expect(abs(violated - 500) < 0.000_001)
    }

    @Test("useful credit decays on the evidence half-life")
    func creditDecays() {
        let start = ContinuousClock.now
        var evidence = PeerEvidence(now: start)
        evidence.recordUsefulReceived(1_000, at: start, halfLife: 10)
        let later = evidence.servingPriority(at: start.advanced(by: .seconds(10)), halfLife: 10)
        #expect(abs(later - 500) < 0.000_001)
    }

    @Test("every other mutation also decays useful credit")
    func otherMutationsDecayCredit() {
        let start = ContinuousClock.now
        let later = start.advanced(by: .seconds(10))
        var evidence = PeerEvidence(now: start)
        evidence.recordUsefulReceived(800, at: start, halfLife: 10)
        evidence.recordSent(1, at: later, halfLife: 10)
        #expect(abs(evidence.usefulBytesReceived - 400) < 0.000_001)
    }

    @Test("at capacity, peers without credit are evicted before helpful ones")
    func evictionKeepsHelpfulPeers() {
        // Capacity = maxPeers × 4 = 4 evidence records.
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        let helpful = PeerID(publicKey: "helpful")
        tally.recordUsefulReceived(peer: helpful, bytes: 1_000)
        // A flood of new identities with only raw traffic.
        for index in 0..<50 {
            tally.recordReceived(peer: PeerID(publicKey: "flood-\(index)"), bytes: 1)
        }
        #expect(tally.peerCount == 4)
        #expect(tally.servingPriority(for: helpful) > 0)
    }

    @Test("without credit anywhere, eviction stays least-recently-used")
    func evictionWithoutCreditIsLRU() {
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        let peers = (0..<5).map { PeerID(publicKey: "peer-\($0)") }
        for peer in peers { tally.recordReceived(peer: peer, bytes: 100) }
        #expect(tally.peerCount == 4)
        // Received bytes give a present peer a positive admission score; an
        // evicted one has no record and scores zero.
        #expect(tally.admissionScore(for: peers[0]) == 0)
        for peer in peers.dropFirst() { #expect(tally.admissionScore(for: peer) > 0) }
    }

    @Test("when every record has credit, a newcomer without credit is the one dropped")
    func newcomerDroppedWhenAllHaveCredit() {
        let tally = Tally(config: TallyConfig(maxPeers: 1))
        let helpful = (0..<4).map { PeerID(publicKey: "helpful-\($0)") }
        for peer in helpful { tally.recordUsefulReceived(peer: peer, bytes: 100) }
        tally.recordReceived(peer: PeerID(publicKey: "newcomer"), bytes: 1)
        #expect(tally.peerCount == 4)
        for peer in helpful { #expect(tally.servingPriority(for: peer) > 0) }
    }
}
