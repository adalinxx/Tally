public struct TallyMetrics: Sendable, Equatable {
    public var allowed: Int = 0
    public var denied: Int = 0
    public var totalBytesSent: Int = 0
    public var totalBytesReceived: Int = 0
    public var challengesIssued: Int = 0
    public var challengesVerified: Int = 0
}
