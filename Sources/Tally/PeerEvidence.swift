import Foundation

struct PeerEvidence: Sendable {
    private(set) var bytesSent: Double = 0
    private(set) var bytesReceived: Double = 0
    /// Bytes of content this node asked the peer for and verified. Unlike
    /// `bytesReceived` it cannot be raised by unsolicited traffic.
    private(set) var usefulBytesReceived: Double = 0
    private(set) var protocolViolations: Double = 0
    private(set) var challengeWork: Double = 0
    private(set) var lastUpdate: ContinuousClock.Instant

    init(now: ContinuousClock.Instant) {
        self.lastUpdate = now
    }

    mutating func recordSent(_ bytes: Int, at now: ContinuousClock.Instant, halfLife: Double) {
        decay(to: now, halfLife: halfLife)
        bytesSent += Double(bytes)
    }

    mutating func recordReceived(_ bytes: Int, at now: ContinuousClock.Instant, halfLife: Double) {
        decay(to: now, halfLife: halfLife)
        bytesReceived += Double(bytes)
    }

    mutating func recordUsefulReceived(_ bytes: Int, at now: ContinuousClock.Instant, halfLife: Double) {
        decay(to: now, halfLife: halfLife)
        usefulBytesReceived += Double(bytes)
    }

    /// How helpful the peer has been: verified content it served on request,
    /// discounted by protocol violations as the admission score is.
    mutating func servingPriority(at now: ContinuousClock.Instant, halfLife: Double) -> Double {
        decay(to: now, halfLife: halfLife)
        return usefulBytesReceived / (1 + protocolViolations)
    }

    mutating func recordProtocolViolation(at now: ContinuousClock.Instant, halfLife: Double) {
        decay(to: now, halfLife: halfLife)
        protocolViolations += 1
    }

    mutating func recordChallengeWork(_ work: Int, at now: ContinuousClock.Instant, halfLife: Double) {
        decay(to: now, halfLife: halfLife)
        challengeWork += Double(work)
    }

    mutating func admissionScore(
        for peer: PeerID,
        at now: ContinuousClock.Instant,
        config: TallyConfig
    ) -> Double {
        decay(to: now, halfLife: config.decayHalfLife)

        let exchange = bytesSent + bytesReceived
        let confidence = min(exchange / config.exchangeBaseline, 1)
        let quality = (bytesReceived + 1) / (exchange + 1)
        let challenge = min(challengeWork / Double(config.hardnessBaseline), 1)
        let keyWork = min(
            Double(KeyDifficulty.keyWorkBits(peer.publicKey)) / Double(config.powBaseline),
            1
        )
        let score = (
            0.50 * confidence * quality
                + 0.25 * challenge
                + 0.25 * confidence * keyWork
        ) / (1 + protocolViolations)
        return min(max(score, 0), 1)
    }

    private mutating func decay(to now: ContinuousClock.Instant, halfLife: Double) {
        let elapsed = lastUpdate.duration(to: now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return }

        let factor = exp2(-seconds / halfLife)
        bytesSent *= factor
        bytesReceived *= factor
        usefulBytesReceived *= factor
        protocolViolations *= factor
        challengeWork *= factor
        lastUpdate = now
    }
}
