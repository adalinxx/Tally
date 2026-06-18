import Foundation

/// Pure behavior → score computation.
///
/// Owns no peer state of its own; it decays and scores a `PeerLedger` slice
/// handed to it under the caller's lock. Extracted from `Tally` to isolate the
/// reputation concern from admission/rate-limiting and challenge accounting.
struct ReputationScorer: Sendable {
    let config: TallyConfig

    /// Decay the ledger to `now` and compute its reputation for `peer`.
    /// Mutates the ledger in place (decay + cached score), matching the prior
    /// read-path behavior in `Tally`.
    func score(_ ledger: inout PeerLedger, peer: PeerID, at now: ContinuousClock.Instant) -> Double {
        ledger.decay(to: now, halfLife: config.decayHalfLife)
        return ledger.reputation(
            weights: config.weights,
            latencyBaseline: config.latencyBaseline,
            hardnessBaseline: config.hardnessBaseline,
            exchangeBaseline: config.exchangeBaseline,
            peerPowBits: peer.trailingZeroBits,
            powBaseline: config.powBaseline
        )
    }

    /// Decay the ledger to `now` and return its debt ratio.
    func debtRatio(_ ledger: inout PeerLedger, at now: ContinuousClock.Instant) -> Double {
        ledger.decay(to: now, halfLife: config.decayHalfLife)
        return ledger.debtRatio
    }
}
