import Foundation

/// Per-peer token buckets + global rate pressure.
///
/// Holds the admission/rate-limiting state that was previously inlined in
/// `Tally.State`: per-peer request buckets and the global send-byte window.
/// Decisions are intentionally fail-closed for unknown peers — a new peer gets
/// a fresh bucket (full capacity) but is still subject to global pressure and,
/// under pressure, to a reputation gate driven by the caller.
struct AdmissionController: Sendable {
    let config: TallyConfig

    var requestBuckets: BoundedMap<PeerID, RequestTokenBucket>
    var windowBytesSent: Int = 0
    var windowStart: ContinuousClock.Instant = .now

    init(config: TallyConfig) {
        self.config = config
        self.requestBuckets = BoundedMap(capacity: config.boundedPeerStateCapacity)
    }

    /// Try to consume one per-peer request token. Returns `true` if a token was
    /// available (and consumed). A brand-new peer starts with a full bucket.
    mutating func consumeRequestToken(peer: PeerID, at now: ContinuousClock.Instant) -> Bool {
        var bucket = requestBuckets.value(forKey: peer) ?? RequestTokenBucket(
            capacity: config.perPeerRequestCapacity,
            refillPerSecond: config.perPeerRequestRefillPerSecond,
            now: now
        )
        let allowed = bucket.tryConsume(at: now)
        requestBuckets.setValue(bucket, forKey: peer)
        return allowed
    }

    mutating func removePeer(_ peer: PeerID) {
        requestBuckets.removeValue(forKey: peer)
    }

    /// Record raw (un-distance-scaled) sent bytes into the global rate window.
    mutating func recordWindowByte(_ bytes: Int, at now: ContinuousClock.Instant) {
        let elapsed = windowStart.duration(to: now)
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSec >= config.rateWindow {
            windowBytesSent = bytes
            windowStart = now
        } else {
            windowBytesSent += bytes
        }
    }

    /// Global rate pressure in `[0, 2]` relative to the configured limit.
    mutating func ratePressure(at now: ContinuousClock.Instant) -> Double {
        let elapsed = windowStart.duration(to: now)
        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSec >= config.rateWindow {
            windowBytesSent = 0
            windowStart = now
            return 0
        }
        let effectiveWindow = max(elapsedSec, 0.001)
        let currentRate = Double(windowBytesSent) / effectiveWindow
        return min(currentRate / config.rateLimitBytesPerSecond, 2.0)
    }

    /// Whether a peer with the given reputation passes the pressure-scaled gate.
    /// Below 0.5 pressure the caller short-circuits to allow; this covers the
    /// `pressure >= 0.5` regime where reputation matters.
    func passesPressureGate(reputation: Double, pressure: Double) -> Bool {
        if pressure >= 1.0 {
            return reputation >= 0.8
        }
        let threshold = (pressure - 0.5) * 2.0
        return reputation >= threshold
    }
}

struct RequestTokenBucket: Sendable {
    var tokens: Double
    var lastRefill: ContinuousClock.Instant
    let capacity: Double
    let refillPerSecond: Double

    init(capacity: Double, refillPerSecond: Double, now: ContinuousClock.Instant) {
        self.capacity = max(capacity, 1)
        self.refillPerSecond = max(refillPerSecond, 0)
        self.tokens = self.capacity
        self.lastRefill = now
    }

    mutating func tryConsume(at now: ContinuousClock.Instant, cost: Double = 1) -> Bool {
        let elapsed = lastRefill.duration(to: now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSeconds > 0 {
            tokens = min(capacity, tokens + elapsedSeconds * refillPerSecond)
            lastRefill = now
        }
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}
