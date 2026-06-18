import Foundation
#if canImport(os)
import os
#endif

/// Composes three cohesive concerns behind a stable public API:
/// - `ReputationScorer`: pure behavior → score.
/// - `AdmissionController`: per-peer token buckets + global rate pressure.
/// - `ChallengeService`: PoW challenge issue/verify.
///
/// `Tally` owns the lock and the peer ledgers; admission state lives inside the
/// `AdmissionController` slice of `State`. All decisions are behavior-preserving
/// relative to the prior monolithic implementation, including the fail-closed
/// default for unknown peers under rate pressure.
public struct Tally: Sendable {
    private let _state: LockedState<State>
    private let config: TallyConfig
    private let scorer: ReputationScorer

    public init(config: TallyConfig = .default) {
        self.config = config
        self.scorer = ReputationScorer(config: config)
        self._state = LockedState(initialState: State(config: config))
    }

    // MARK: - Recording (no decay on write path)

    public func recordSent(peer: PeerID, bytes: Int, cpl: Int? = nil) {
        _state.withLock { state in
            let now = ContinuousClock.now
            let effective = Self.distanceScaled(bytes: bytes, cpl: cpl)
            state.admission.recordWindowByte(bytes, at: now)
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.bytesSent.add(effective)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
            state.metrics.totalBytesSent += bytes
        }
    }

    public func recordReceived(peer: PeerID, bytes: Int, cpl: Int? = nil) {
        _state.withLock { state in
            let now = ContinuousClock.now
            let effective = Self.distanceScaled(bytes: bytes, cpl: cpl)
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.bytesReceived.add(effective)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
            state.metrics.totalBytesReceived += bytes
        }
    }

    @inline(__always)
    private static func distanceScaled(bytes: Int, cpl: Int?) -> Int {
        guard let cpl else { return bytes }
        let multiplier = Double(256 - min(max(cpl, 0), 256)) / 256.0
        return Int(Double(bytes) * multiplier)
    }

    public func recordRequest(peer: PeerID) {
        _state.withLock { state in
            let now = ContinuousClock.now
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
        }
    }

    public func recordSuccess(peer: PeerID) {
        _state.withLock { state in
            let now = ContinuousClock.now
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.successCount.add(1)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
        }
    }

    public func recordFailure(peer: PeerID) {
        _state.withLock { state in
            let now = ContinuousClock.now
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.failureCount.add(1)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
        }
    }

    public func recordLatency(peer: PeerID, microseconds: Double) {
        _state.withLock { state in
            let now = ContinuousClock.now
            guard var ledger = state.ledger(for: peer) else { return }
            ledger.latencyEWMA.record(microseconds)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
        }
    }

    // MARK: - Gating (decay lazily on read path only)

    public func shouldAllow(peer: PeerID) -> Bool {
        _state.withLock { state in
            let now = ContinuousClock.now

            guard state.admission.consumeRequestToken(peer: peer, at: now) else {
                state.metrics.denied += 1
                return false
            }

            var requestLedger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            requestLedger.lastSeen = now
            requestLedger.markStale()
            state.storeLedger(requestLedger, for: peer, at: now, scorer: scorer)

            let pressure = state.admission.ratePressure(at: now)

            if pressure < 0.5 {
                state.metrics.allowed += 1
                return true
            }

            var rep: Double = 0
            if var ledger = state.ledger(for: peer) {
                rep = scorer.score(&ledger, peer: peer, at: now)
                state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
            }

            let allowed = state.admission.passesPressureGate(reputation: rep, pressure: pressure)

            if allowed {
                state.metrics.allowed += 1
            } else {
                state.metrics.denied += 1
            }
            return allowed
        }
    }

    // MARK: - Challenges

    public func issueChallenge(for peer: PeerID) -> Challenge {
        _state.withLock { state in
            let challenge = state.challenges.issue(for: peer)
            state.metrics.challengesIssued += 1
            return challenge
        }
    }

    public func verifyChallenge(_ challenge: Challenge, solution: Data, peer: PeerID) -> Bool {
        _state.withLock { state in
            let now = ContinuousClock.now
            guard state.challenges.verify(challenge, solution: solution, peer: peer) else { return false }
            var ledger = state.ledger(for: peer) ?? PeerLedger(now: now, latencyAlpha: config.latencyAlpha)
            ledger.challengeHardness.add(challenge.difficulty)
            ledger.lastSeen = now
            ledger.markStale()
            state.storeLedger(ledger, for: peer, at: now, scorer: scorer)
            state.metrics.challengesVerified += 1
            return true
        }
    }

    // MARK: - Queries

    public func reputation(for peer: PeerID) -> Double {
        _state.withLock { state in
            guard var ledger = state.ledger(for: peer) else { return 0 }
            let rep = scorer.score(&ledger, peer: peer, at: .now)
            state.storeLedger(ledger, for: peer, at: .now, scorer: scorer)
            return rep
        }
    }

    public func debtRatio(for peer: PeerID) -> Double {
        _state.withLock { state in
            guard var ledger = state.ledger(for: peer) else { return 0 }
            let ratio = scorer.debtRatio(&ledger, at: .now)
            state.storeLedger(ledger, for: peer, at: .now, scorer: scorer)
            return ratio
        }
    }

    public func peerLedger(for peer: PeerID) -> PeerLedger? {
        _state.withLock { state in
            state.ledger(for: peer)
        }
    }

    public func allPeers() -> [PeerID] {
        _state.withLock { state in
            state.ledgers.keys
        }
    }

    /// Drop all reputation/admission state for a peer. (Formerly also exposed
    /// as `removePeer`; collapsed to the one name consumers actually call.)
    public func resetPeer(_ peer: PeerID) {
        _state.withLock { state in
            state.removePeer(peer)
        }
    }

    public var metrics: TallyMetrics {
        _state.withLock { $0.metrics }
    }

    public var peerCount: Int {
        _state.withLock { $0.ledgers.count }
    }

    public func ratePressure() -> Double {
        _state.withLock { state in
            state.admission.ratePressure(at: .now)
        }
    }
}

extension Tally {
    struct State: Sendable {
        var ledgers: BoundedMap<PeerID, PeerLedger>
        var admission: AdmissionController
        var challenges: ChallengeService
        var metrics = TallyMetrics()

        init(config: TallyConfig) {
            self.ledgers = BoundedMap(capacity: config.boundedPeerStateCapacity)
            self.admission = AdmissionController(config: config)
            self.challenges = ChallengeService(config: config)
        }

        func ledger(for peer: PeerID) -> PeerLedger? {
            ledgers.value(forKey: peer)
        }

        mutating func storeLedger(_ ledger: PeerLedger, for peer: PeerID, at now: ContinuousClock.Instant, scorer: ReputationScorer) {
            ledgers.setValue(ledger, forKey: peer) { storage, accessOrder in
                storage.min { lhs, rhs in
                    var lhsLedger = lhs.value
                    var rhsLedger = rhs.value
                    let lhsReputation = scorer.score(&lhsLedger, peer: lhs.key, at: now)
                    let rhsReputation = scorer.score(&rhsLedger, peer: rhs.key, at: now)
                    if lhsReputation != rhsReputation {
                        return lhsReputation < rhsReputation
                    }
                    if lhs.value.lastSeen != rhs.value.lastSeen {
                        return lhs.value.lastSeen < rhs.value.lastSeen
                    }
                    return accessOrder[lhs.key, default: 0] < accessOrder[rhs.key, default: 0]
                }?.key
            }
        }

        mutating func removePeer(_ peer: PeerID) {
            ledgers.removeValue(forKey: peer)
            admission.removePeer(peer)
        }
    }
}
