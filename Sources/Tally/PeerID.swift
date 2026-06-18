import Foundation

public struct PeerID: Hashable, Sendable, CustomStringConvertible {
    public let publicKey: String
    public let trailingZeroBits: Int

    public init(publicKey: String) {
        self.publicKey = publicKey
        self.trailingZeroBits = KeyDifficulty.trailingZeroBits(of: publicKey)
    }

    public var description: String { publicKey }
}
