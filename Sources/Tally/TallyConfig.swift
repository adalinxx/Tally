public struct TallyConfig: Sendable {
    public let weights: ReputationWeights
    public let latencyBaseline: Double
    public let latencyAlpha: Double
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
        weights: ReputationWeights = .default,
        latencyBaseline: Double = 100_000,
        latencyAlpha: Double = 0.3,
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
        self.weights = weights
        self.latencyBaseline = latencyBaseline
        self.latencyAlpha = latencyAlpha
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
