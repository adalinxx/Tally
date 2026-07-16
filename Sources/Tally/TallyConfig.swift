public struct TallyConfig: Sendable {
    public let decayHalfLife: Double
    public let challengeDifficulty: Int
    public let challengeExpiration: Duration
    public let rateLimitBytesPerSecond: Double
    public let rateWindow: Double
    public let perPeerRequestCapacity: Double
    public let perPeerRequestRefillPerSecond: Double
    public let hardnessBaseline: Int
    public let exchangeBaseline: Double
    public let powBaseline: Int
    public let maxPeers: Int?

    public init(
        decayHalfLife: Double = 3600,
        challengeDifficulty: Int = 16,
        challengeExpiration: Duration = .seconds(30),
        rateLimitBytesPerSecond: Double = 10_000_000,
        rateWindow: Double = 1.0,
        perPeerRequestCapacity: Double = 200,
        perPeerRequestRefillPerSecond: Double = 50,
        hardnessBaseline: Int = 160,
        exchangeBaseline: Double = 100_000,
        powBaseline: Int = 16,
        maxPeers: Int? = nil
    ) {
        precondition(decayHalfLife.isFinite && decayHalfLife > 0, "decayHalfLife must be finite and positive")
        precondition((0...256).contains(challengeDifficulty), "challengeDifficulty must be between 0 and 256")
        precondition(challengeExpiration > .zero, "challengeExpiration must be positive")
        precondition(rateLimitBytesPerSecond.isFinite && rateLimitBytesPerSecond > 0, "rateLimitBytesPerSecond must be finite and positive")
        precondition(rateWindow.isFinite && rateWindow > 0, "rateWindow must be finite and positive")
        precondition(
            (rateLimitBytesPerSecond * rateWindow).isFinite
                && rateLimitBytesPerSecond * rateWindow > 0,
            "rate limit window budget must be finite and positive"
        )
        precondition(perPeerRequestCapacity.isFinite && perPeerRequestCapacity >= 1, "perPeerRequestCapacity must be finite and at least one")
        precondition(perPeerRequestRefillPerSecond.isFinite && perPeerRequestRefillPerSecond >= 0, "perPeerRequestRefillPerSecond must be finite and non-negative")
        precondition(hardnessBaseline > 0, "hardnessBaseline must be positive")
        precondition(exchangeBaseline.isFinite && exchangeBaseline > 0, "exchangeBaseline must be finite and positive")
        precondition(powBaseline > 0, "powBaseline must be positive")
        precondition(maxPeers.map { $0 > 0 } ?? true, "maxPeers must be positive")

        self.decayHalfLife = decayHalfLife
        self.challengeDifficulty = challengeDifficulty
        self.challengeExpiration = challengeExpiration
        self.rateLimitBytesPerSecond = rateLimitBytesPerSecond
        self.rateWindow = rateWindow
        self.perPeerRequestCapacity = perPeerRequestCapacity
        self.perPeerRequestRefillPerSecond = perPeerRequestRefillPerSecond
        self.hardnessBaseline = hardnessBaseline
        self.exchangeBaseline = exchangeBaseline
        self.powBaseline = powBaseline
        self.maxPeers = maxPeers
    }

    public static let `default` = TallyConfig()
}
