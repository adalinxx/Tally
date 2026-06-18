import Foundation

public struct CreditLine: Sendable {
    public let peerA: PeerID
    public let peerB: PeerID
    public private(set) var balance: Int64
    public private(set) var sequence: UInt64
    public private(set) var threshold: UInt64
    public private(set) var successfulSettlements: UInt64

    public init(peerA: PeerID, peerB: PeerID, threshold: UInt64) {
        self.peerA = peerA
        self.peerB = peerB
        self.balance = 0
        self.sequence = 0
        self.threshold = threshold
        self.successfulSettlements = 0
    }

    public static func initialThreshold(baseTrust: Double, multiplier: UInt64 = 100) -> UInt64 {
        UInt64(baseTrust * Double(multiplier))
    }

    public var needsSettlement: Bool {
        clampedBalanceMagnitude >= clampedThreshold
    }

    public var availableCapacity: Int64 {
        clampedThreshold - clampedBalanceMagnitude
    }

    /// Continuous debt pressure from 0.0 (no debt) to 1.0 (at or past threshold).
    /// Use for graduated throttling: higher pressure → less bandwidth allocated.
    public var debtPressure: Double {
        let threshold = clampedThreshold
        guard threshold > 0 else { return 1.0 }
        return min(Double(clampedBalanceMagnitude) / Double(threshold), 1.0)
    }

    private var clampedThreshold: Int64 {
        Int64(min(threshold, UInt64(Int64.max)))
    }

    private var clampedBalanceMagnitude: Int64 {
        Int64(min(balance.magnitude, UInt64(Int64.max)))
    }

    public mutating func adjustBalance(by amount: Int64) {
        balance += amount
        sequence += 1
    }

    public mutating func recordSettlement() {
        balance = 0
        successfulSettlements += 1
        let initial = threshold / UInt64(1 + log2(Double(successfulSettlements)))
        threshold = initial * UInt64(1 + log2(Double(successfulSettlements + 1)))
    }

    public mutating func recordPartialSettlement(workValue: Int64) {
        if balance > 0 {
            balance = max(0, balance - workValue)
        } else {
            balance = min(0, balance + workValue)
        }
        sequence += 1
    }

    public mutating func recordMissedSettlement() {
        threshold = threshold / 2
    }
}
