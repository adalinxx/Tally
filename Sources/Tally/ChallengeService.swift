import Foundation

/// Issues PoW challenges and verifies solutions.
///
/// Verification consumes one outstanding nonce on a valid solution; on success
/// the caller credits the peer's challenge hardness. Extracted from `Tally` to
/// isolate the challenge concern from reputation and admission.
struct ChallengeService: Sendable {
    let config: TallyConfig
    private var outstandingNonces: BoundedMap<Data, OutstandingChallenge>

    init(config: TallyConfig) {
        self.config = config
        self.outstandingNonces = BoundedMap(capacity: config.outstandingChallengeCapacity)
    }

    mutating func issue(for peer: PeerID) -> Challenge {
        let now = ContinuousClock.now
        pruneExpired(at: now)

        let challenge = Challenge(
            boundPeer: peer,
            difficulty: config.challengeDifficulty,
            expiresAfter: config.challengeExpiration
        )
        outstandingNonces.setValue(
            OutstandingChallenge(challenge),
            forKey: challenge.nonce
        ) { storage, accessOrder in
            storage.first { $0.value.isExpired(at: now) }?.key
                ?? accessOrder.min { lhs, rhs in lhs.value < rhs.value }?.key
        }
        return challenge
    }

    mutating func verify(_ challenge: Challenge, solution: Data, peer: PeerID) -> Bool {
        let now = ContinuousClock.now
        pruneExpired(at: now)

        guard challenge.boundPeer == peer else { return false }
        guard let outstanding = outstandingNonces.value(forKey: challenge.nonce) else { return false }
        guard outstanding.matches(challenge), !outstanding.isExpired(at: now) else {
            outstandingNonces.removeValue(forKey: challenge.nonce)
            return false
        }
        guard challenge.verify(solution: solution, peer: peer, at: now) else { return false }

        outstandingNonces.removeValue(forKey: challenge.nonce)
        return true
    }

    var outstandingCount: Int {
        outstandingNonces.count
    }

    private mutating func pruneExpired(at now: ContinuousClock.Instant) {
        outstandingNonces.removeAll { _, challenge in
            challenge.isExpired(at: now)
        }
    }
}

private struct OutstandingChallenge: Sendable {
    let boundPeer: PeerID
    let difficulty: Int
    let issuedAt: ContinuousClock.Instant
    let expiresAfter: Duration

    init(_ challenge: Challenge) {
        self.boundPeer = challenge.boundPeer
        self.difficulty = challenge.difficulty
        self.issuedAt = challenge.issuedAt
        self.expiresAfter = challenge.expiresAfter
    }

    func matches(_ challenge: Challenge) -> Bool {
        boundPeer == challenge.boundPeer
            && difficulty == challenge.difficulty
            && expiresAfter == challenge.expiresAfter
    }

    func isExpired(at now: ContinuousClock.Instant) -> Bool {
        issuedAt.duration(to: now) >= expiresAfter
    }
}
