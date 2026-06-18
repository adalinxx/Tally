import Testing
import Foundation
@testable import Tally

@Suite("Tally")
struct TallyTests {

    @Test("Fresh peer is allowed when under rate limit")
    func testFreshPeerAllowed() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc123")
        #expect(tally.shouldAllow(peer: peer) == true)
    }

    @Test("Record sent tracks bytes")
    func testRecordSent() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc123")
        tally.recordSent(peer: peer, bytes: 500)
        let ledger = tally.peerLedger(for: peer)!
        #expect(ledger.bytesSent.value >= 499)
    }

    @Test("Record received tracks bytes")
    func testRecordReceived() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc123")
        tally.recordReceived(peer: peer, bytes: 300)
        let ledger = tally.peerLedger(for: peer)!
        #expect(ledger.bytesReceived.value >= 299)
    }

    @Test("Record request creates a ledger entry")
    func testRecordRequest() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc123")
        tally.recordRequest(peer: peer)
        #expect(tally.peerLedger(for: peer) != nil)
    }

    @Test("Record success and failure")
    func testSuccessFailure() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc")
        tally.recordRequest(peer: peer)
        tally.recordSuccess(peer: peer)
        tally.recordFailure(peer: peer)
        let ledger = tally.peerLedger(for: peer)!
        #expect(ledger.successCount.value == 1)
        #expect(ledger.failureCount.value == 1)
    }

    @Test("Failure creates ledger for unknown peer")
    func testFailureCreatesLedger() {
        let tally = Tally()
        let peer = PeerID(publicKey: "unknown-failure")
        tally.recordFailure(peer: peer)
        #expect(tally.peerLedger(for: peer)?.failureCount.value == 1)
        #expect(tally.reputation(for: peer) == 0)
    }

    @Test("Record latency uses EWMA")
    func testRecordLatency() {
        let tally = Tally()
        let peer = PeerID(publicKey: "abc")
        tally.recordRequest(peer: peer)
        tally.recordLatency(peer: peer, microseconds: 100)
        tally.recordLatency(peer: peer, microseconds: 200)
        let ewma = tally.peerLedger(for: peer)!.latencyEWMA
        #expect(ewma.count == 2)
        #expect(ewma.value > 100 && ewma.value < 200)
    }

    @Test("recordLatency uses the configured latencyAlpha")
    func testRecordLatencyUsesConfiguredAlpha() {
        // alpha = 1.0: the EWMA must equal the most recent sample exactly.
        let tally = Tally(config: TallyConfig(latencyAlpha: 1.0))
        let peer = PeerID(publicKey: "alpha-wired")
        tally.recordRequest(peer: peer)
        tally.recordLatency(peer: peer, microseconds: 100)
        tally.recordLatency(peer: peer, microseconds: 900)
        #expect(tally.peerLedger(for: peer)?.latencyEWMA.value == 900,
                "config.latencyAlpha must reach the ledger EWMA (default 0.3 would give 660)")
    }

    @Test("High-reputation peer allowed under pressure")
    func testHighRepAllowedUnderPressure() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 100))
        let peer = PeerID(publicKey: "good")
        tally.recordReceived(peer: peer, bytes: 10000)
        for _ in 0..<10 { tally.recordSuccess(peer: peer) }
        tally.recordLatency(peer: peer, microseconds: 1000)
        tally.recordSent(peer: peer, bytes: 200)
        #expect(tally.reputation(for: peer) > 0.5)
    }

    @Test("Low-reputation peer denied under pressure")
    func testLowRepDeniedUnderPressure() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 100))
        let freeloader = PeerID(publicKey: "freeloader")
        tally.recordSent(peer: freeloader, bytes: 500)
        #expect(tally.shouldAllow(peer: freeloader) == false)
    }

    @Test("Reputation returns zero for unknown peer")
    func testReputationUnknown() {
        let tally = Tally()
        #expect(tally.reputation(for: PeerID(publicKey: "ghost")) == 0)
    }

    @Test("Multiple peers tracked independently")
    func testMultiplePeers() {
        let tally = Tally()
        let alice = PeerID(publicKey: "alice")
        let bob = PeerID(publicKey: "bob")
        tally.recordSent(peer: alice, bytes: 100)
        tally.recordSent(peer: bob, bytes: 200)
        #expect(tally.peerLedger(for: alice)!.bytesSent.value >= 99)
        #expect(tally.peerLedger(for: bob)!.bytesSent.value >= 199)
    }

    @Test("Reset peer removes ledger")
    func testResetPeer() {
        let tally = Tally()
        let peer = PeerID(publicKey: "reset-me")
        tally.recordSent(peer: peer, bytes: 100)
        tally.resetPeer(peer)
        #expect(tally.peerLedger(for: peer) == nil)
    }

    @Test("Reset peer clears admission request bucket")
    func testResetPeerClearsRequestBucket() {
        let tally = Tally(config: TallyConfig(
            perPeerRequestCapacity: 1,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "reset-bucket")

        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.shouldAllow(peer: peer))
        tally.resetPeer(peer)
        #expect(tally.shouldAllow(peer: peer))
    }

    @Test("allPeers returns tracked peers")
    func testAllPeers() {
        let tally = Tally()
        let a = PeerID(publicKey: "a")
        let b = PeerID(publicKey: "b")
        tally.recordSent(peer: a, bytes: 1)
        tally.recordSent(peer: b, bytes: 1)
        #expect(Set(tally.allPeers()) == Set([a, b]))
    }

    @Test("Metrics track allowed and denied")
    func testMetrics() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 100))
        let peer = PeerID(publicKey: "test")
        _ = tally.shouldAllow(peer: peer)
        tally.recordSent(peer: peer, bytes: 500)
        _ = tally.shouldAllow(peer: peer)
        let m = tally.metrics
        #expect(m.allowed + m.denied == 2)
    }

    @Test("Per-peer request bucket denies bursts below global pressure")
    func testPerPeerRequestBucketDeniesBurst() {
        let tally = Tally(config: TallyConfig(
            rateLimitBytesPerSecond: 1_000_000_000,
            perPeerRequestCapacity: 2,
            perPeerRequestRefillPerSecond: 0
        ))
        let peer = PeerID(publicKey: "burst-peer")

        #expect(tally.shouldAllow(peer: peer))
        #expect(tally.shouldAllow(peer: peer))
        #expect(!tally.shouldAllow(peer: peer))
    }

    @Test("Metrics track total bytes")
    func testMetricsTotalBytes() {
        let tally = Tally()
        let peer = PeerID(publicKey: "test")
        tally.recordSent(peer: peer, bytes: 100)
        tally.recordReceived(peer: peer, bytes: 50)
        let m = tally.metrics
        #expect(m.totalBytesSent == 100)
        #expect(m.totalBytesReceived == 50)
    }

    @Test("Peer count")
    func testPeerCount() {
        let tally = Tally()
        #expect(tally.peerCount == 0)
        tally.recordSent(peer: PeerID(publicKey: "a"), bytes: 1)
        tally.recordSent(peer: PeerID(publicKey: "b"), bytes: 1)
        #expect(tally.peerCount == 2)
    }

    @Test("Ledger map stays bounded and evicts lowest reputation LRU")
    func testBoundedLedgersEvictLowestReputationLRU() {
        let config = TallyConfig(maxPeers: 1)
        let tally = Tally(config: config)
        let cap = config.boundedPeerStateCapacity
        let staleLow = PeerID(publicKey: "stale-low")
        let highRep = PeerID(publicKey: "high-rep")

        tally.recordRequest(peer: staleLow)
        tally.recordReceived(peer: highRep, bytes: 100_000)
        for _ in 0..<10 { tally.recordSuccess(peer: highRep) }

        for i in 0..<(cap - 2) {
            tally.recordRequest(peer: PeerID(publicKey: "low-\(i)"))
        }
        #expect(tally.peerCount == cap)

        tally.recordRequest(peer: PeerID(publicKey: "new-low"))
        #expect(tally.peerCount <= cap)
        #expect(tally.peerLedger(for: highRep) != nil)
        #expect(tally.peerLedger(for: staleLow) == nil)
    }

    @Test("Rate pressure reflects sent bytes")
    func testRatePressure() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 1000))
        let peer = PeerID(publicKey: "a")
        tally.recordSent(peer: peer, bytes: 500)
        #expect(tally.ratePressure() > 0)
    }

    @Test("Decay reduces old byte counters")
    func testDecayReducesCounters() {
        let tally = Tally(config: TallyConfig(decayHalfLife: 0.001))
        let peer = PeerID(publicKey: "decay-test")
        tally.recordSent(peer: peer, bytes: 1000)
        let ratio = tally.debtRatio(for: peer)
        #expect(ratio < 1000)
    }

    @Test("Far data (low CPL) earns more credit than near data")
    func testDistanceScaling() {
        let tally = Tally()
        let far = PeerID(publicKey: "far")
        let near = PeerID(publicKey: "near")
        tally.recordReceived(peer: far, bytes: 1000, cpl: 0)
        tally.recordReceived(peer: near, bytes: 1000, cpl: 200)
        let farCredit = tally.peerLedger(for: far)!.bytesReceived.value
        let nearCredit = tally.peerLedger(for: near)!.bytesReceived.value
        #expect(farCredit > nearCredit)
    }

    @Test("CPL 0 gives full credit, CPL 256 gives zero")
    func testDistanceScalingBounds() {
        let tally = Tally()
        let a = PeerID(publicKey: "a")
        let b = PeerID(publicKey: "b")
        tally.recordReceived(peer: a, bytes: 1000, cpl: 0)
        tally.recordReceived(peer: b, bytes: 1000, cpl: 256)
        #expect(tally.peerLedger(for: a)!.bytesReceived.value == 1000)
        #expect(tally.peerLedger(for: b)!.bytesReceived.value == 0)
    }

    @Test("No CPL means no scaling")
    func testNoCPLNoScaling() {
        let tally = Tally()
        let peer = PeerID(publicKey: "p")
        tally.recordReceived(peer: peer, bytes: 1000)
        #expect(tally.peerLedger(for: peer)!.bytesReceived.value == 1000)
    }

    @Test("recordSent scales by CPL")
    func testSentDistanceScaled() {
        let tally = Tally()
        let far = PeerID(publicKey: "far")
        let near = PeerID(publicKey: "near")
        tally.recordSent(peer: far, bytes: 1000, cpl: 0)
        tally.recordSent(peer: near, bytes: 1000, cpl: 200)
        #expect(tally.peerLedger(for: far)!.bytesSent.value > tally.peerLedger(for: near)!.bytesSent.value)
    }

    @Test("recordSent without CPL is unscaled")
    func testSentNoCPL() {
        let tally = Tally()
        let peer = PeerID(publicKey: "p")
        tally.recordSent(peer: peer, bytes: 1000)
        #expect(tally.peerLedger(for: peer)!.bytesSent.value == 1000)
    }

    @Test("Rate pressure uses raw bytes not distance-scaled")
    func testRatePressureRawBytes() {
        let tally = Tally(config: TallyConfig(rateLimitBytesPerSecond: 1000))
        let peer = PeerID(publicKey: "a")
        tally.recordSent(peer: peer, bytes: 500, cpl: 256)
        #expect(tally.ratePressure() > 0)
    }

    @Test("PeerID trailing zero bits computed from SHA-256 hash")
    func testPeerIDTrailingZeroBits() {
        #expect(PeerID(publicKey: "abc").trailingZeroBits == 0)
        #expect(PeerID(publicKey: "abc123").trailingZeroBits == 4)
        #expect(PeerID(publicKey: "peer-4587").trailingZeroBits == 17)
        #expect(PeerID(publicKey: "peer-0").trailingZeroBits == 0)
    }

    @Test("keyWorkBits: prefixed and raw forms of the same key measure identically")
    func testKeyWorkBitsPrefixedRawParity() {
        // Grind a raw 64-hex key with >= 8 work bits whose ed01-prefixed
        // spelling, hashed VERBATIM, would score below 8 — i.e. a key that an
        // unnormalized gate would wrongly reject when presented prefixed.
        var raw = ""
        var rng = SystemRandomNumberGenerator()
        while true {
            raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
            if KeyDifficulty.trailingZeroBits(of: raw) >= 8,
               KeyDifficulty.trailingZeroBits(of: "ed01" + raw) < 8 {
                break
            }
        }
        let prefixed = "ed01" + raw
        #expect(KeyDifficulty.canonicalRawHex(prefixed) == raw)
        #expect(KeyDifficulty.canonicalRawHex(raw) == raw)
        #expect(KeyDifficulty.keyWorkBits(prefixed) == KeyDifficulty.keyWorkBits(raw))
        #expect(KeyDifficulty.keyWorkBits(raw) >= 8)
        #expect(KeyDifficulty.keyWorkBits(raw) == KeyDifficulty.trailingZeroBits(of: raw))
    }

    @Test("canonicalRawHex: stripping is prefix+length based, everything else passes through verbatim")
    func testCanonicalRawHexPassthrough() {
        // Wrong length: ed01 prefix but not 68 chars — passthrough.
        let short = "ed01" + String(repeating: "a", count: 60)
        #expect(KeyDifficulty.canonicalRawHex(short) == short)
        let long = "ed01" + String(repeating: "a", count: 66)
        #expect(KeyDifficulty.canonicalRawHex(long) == long)
        // No prefix: passthrough, measured as presented.
        let opaque = "peer-4587"
        #expect(KeyDifficulty.canonicalRawHex(opaque) == opaque)
        #expect(KeyDifficulty.keyWorkBits(opaque) == KeyDifficulty.trailingZeroBits(of: opaque))
        // 68 chars with ed01 prefix is stripped even if the payload is not
        // valid hex — canonicalization does not validate, gates do.
        let junk = "ed01" + String(repeating: "z", count: 64)
        #expect(KeyDifficulty.canonicalRawHex(junk) == String(repeating: "z", count: 64))
        // Empty string: passthrough.
        #expect(KeyDifficulty.canonicalRawHex("") == "")
    }

    @Test("POW does not create reputation for new peers")
    func testPowRequiresExchange() {
        let config = TallyConfig(
            weights: ReputationWeights(reciprocity: 0, latency: 0, successRate: 0, challenges: 0, pow: 0.1),
            powBaseline: 16
        )
        let tally = Tally(config: config)
        let highPow = PeerID(publicKey: "peer-4587")
        let lowPow = PeerID(publicKey: "peer-0")
        tally.recordRequest(peer: highPow)
        tally.recordRequest(peer: lowPow)
        #expect(tally.reputation(for: highPow) == tally.reputation(for: lowPow))

        tally.recordReceived(peer: highPow, bytes: 100_000)
        #expect(tally.reputation(for: highPow) > tally.reputation(for: lowPow))
    }

    @Test("POW floor does not exceed behavioral reputation")
    func testPowFloorDoesNotExceedBehavioral() {
        let tally = Tally(config: TallyConfig(powBaseline: 16))
        let peer = PeerID(publicKey: "peer-4587")
        tally.recordReceived(peer: peer, bytes: 100_000)
        for _ in 0..<20 { tally.recordSuccess(peer: peer) }
        tally.recordLatency(peer: peer, microseconds: 1000)
        let rep = tally.reputation(for: peer)
        #expect(rep > 0.1)
    }

    @Test("POW does not influence distance scaling")
    func testPowDoesNotAffectDistanceScaling() {
        let tally = Tally()
        let highPow = PeerID(publicKey: "peer-4587")
        let lowPow = PeerID(publicKey: "peer-0")
        tally.recordReceived(peer: highPow, bytes: 1000, cpl: 128)
        tally.recordReceived(peer: lowPow, bytes: 1000, cpl: 128)
        let highCredit = tally.peerLedger(for: highPow)!.bytesReceived.value
        let lowCredit = tally.peerLedger(for: lowPow)!.bytesReceived.value
        #expect(highCredit == lowCredit)
    }
}
