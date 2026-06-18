import Foundation

public struct PeerLedger: Sendable {
    public var bytesSent: DecayingCounter
    public var bytesReceived: DecayingCounter
    public var successCount: DecayingCounter
    public var failureCount: DecayingCounter
    public var challengeHardness: DecayingCounter
    public var firstSeen: ContinuousClock.Instant
    public var lastSeen: ContinuousClock.Instant
    public internal(set) var latencyEWMA: EWMA

    var cachedReputation: Double = 0
    var reputationStale: Bool = true

    public var debtRatio: Double {
        bytesSent.value / (bytesReceived.value + 1)
    }

    public var reciprocity: Double {
        1.0 / (1.0 + debtRatio)
    }

    public var successRate: Double {
        let successes = successCount.value
        let failures = failureCount.value
        let total = successes + failures
        guard total > DecayingCounter.minimumRetainedValue else { return 0.5 }
        return successes / total
    }

    public var failurePenalty: Double {
        let successes = successCount.value
        let failures = failureCount.value
        let total = successes + failures
        guard total > DecayingCounter.minimumRetainedValue else { return 0 }
        let rate = failures / total
        return rate * rate
    }

    public mutating func reputation(weights: ReputationWeights = .default, latencyBaseline: Double = 100_000, hardnessBaseline: Int = 160, exchangeBaseline: Double = 100_000, peerPowBits: Int = 0, powBaseline: Int = 16) -> Double {
        if !reputationStale { return cachedReputation }
        let totalExchange = bytesSent.value + bytesReceived.value
        let confidence = Swift.min(totalExchange / exchangeBaseline, 1.0)
        let totalOutcomes = successCount.value + failureCount.value
        let outcomeConfidence = Swift.min(totalOutcomes, 1.0)
        let r = weights.reciprocity * confidence * reciprocity
        let l = latencyEWMA.count > 0 ? weights.latency * latencyScore(baseline: latencyBaseline) : 0
        let s = totalOutcomes > DecayingCounter.minimumRetainedValue
            ? weights.successRate * outcomeConfidence * max(successRate - failurePenalty, 0)
            : 0
        let c = weights.challenges * min(challengeHardness.value / Double(hardnessBaseline), 1.0)
        let behavioral = Swift.min(Swift.max(r + l + s + c, 0), 1.0)
        let powBonus = confidence * weights.pow * Swift.min(Double(peerPowBits) / Double(powBaseline), 1.0)
        let rep = Swift.min(behavioral + powBonus, 1.0)
        cachedReputation = rep
        reputationStale = false
        return rep
    }

    func latencyScore(baseline: Double) -> Double {
        guard latencyEWMA.value > 0 else { return 0.5 }
        return min(baseline / (latencyEWMA.value + 1), 1.0)
    }

    mutating func decay(to now: ContinuousClock.Instant, halfLife: Double) {
        bytesSent.decay(to: now, halfLife: halfLife)
        bytesReceived.decay(to: now, halfLife: halfLife)
        successCount.decay(to: now, halfLife: halfLife)
        failureCount.decay(to: now, halfLife: halfLife)
        challengeHardness.decay(to: now, halfLife: halfLife)
        reputationStale = true
    }

    mutating func markStale() {
        reputationStale = true
    }

    init(now: ContinuousClock.Instant, latencyAlpha: Double = 0.3) {
        self.bytesSent = DecayingCounter(lastDecay: now)
        self.bytesReceived = DecayingCounter(lastDecay: now)
        self.successCount = DecayingCounter(lastDecay: now)
        self.failureCount = DecayingCounter(lastDecay: now)
        self.challengeHardness = DecayingCounter(lastDecay: now)
        self.firstSeen = now
        self.lastSeen = now
        self.latencyEWMA = EWMA(alpha: latencyAlpha)
    }
}

public struct DecayingCounter: Sendable {
    static let minimumRetainedValue = 1e-9

    public var value: Double = 0
    public var lastDecay: ContinuousClock.Instant

    @inline(__always)
    public mutating func add(_ amount: Int) {
        value += Double(amount)
    }

    @inline(__always)
    public mutating func decay(to now: ContinuousClock.Instant, halfLife: Double) {
        let elapsed = lastDecay.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        value *= exp2(-seconds / halfLife)
        if value < Self.minimumRetainedValue {
            value = 0
        }
        lastDecay = now
    }
}

public struct EWMA: Sendable {
    public var value: Double = 0
    public var count: Int = 0
    private let alpha: Double

    public init(alpha: Double = 0.3) {
        self.alpha = alpha
    }

    @inline(__always)
    public mutating func record(_ sample: Double) {
        if count == 0 {
            value = sample
        } else {
            value = alpha * sample + (1 - alpha) * value
        }
        count += 1
    }
}

public struct ReputationWeights: Sendable {
    public let reciprocity: Double
    public let latency: Double
    public let successRate: Double
    public let challenges: Double
    public let pow: Double

    public init(reciprocity: Double = 0.2, latency: Double = 0.3, successRate: Double = 0.4, challenges: Double = 0.1, pow: Double = 0.1) {
        self.reciprocity = reciprocity
        self.latency = latency
        self.successRate = successRate
        self.challenges = challenges
        self.pow = pow
    }

    public static let `default` = ReputationWeights()
}
