import Foundation
import Crypto

public enum KeyDifficulty: Sendable {

    public static func trailingZeroBits(of publicKey: String) -> Int {
        let hash = SHA256.hash(data: Data(publicKey.utf8))
        var count = 0
        for byte in hash.reversed() {
            if byte == 0 {
                count += 8
            } else {
                count += byte.trailingZeroBitCount
                break
            }
        }
        return count
    }

    /// Canonical raw-hex form of a presented public key.
    ///
    /// Ed25519 keys travel in two spellings: the raw 64-hex form and the
    /// `ed01`-prefixed Multikey form (2-byte multicodec prefix → 68 hex chars).
    /// This strips the Multikey prefix down to the raw form; anything else —
    /// including malformed strings (wrong length, non-hex) — passes through
    /// verbatim, so an opaque or junk key is simply measured as presented
    /// rather than rejected here. Gates that need validity must check it
    /// separately; this function only collapses the two spellings of the
    /// SAME key onto one canonical string.
    public static func canonicalRawHex(_ presented: String) -> String {
        if presented.hasPrefix("ed01") && presented.count == 68 {
            return String(presented.dropFirst(4))
        }
        return presented
    }

    /// THE single measure for identity-PoW gates: trailing-zero bits of
    /// SHA-256 over the canonical raw-hex key form.
    ///
    /// Every identity-PoW gate (Ivy identify/routing gates, lattice-node
    /// PeerDiversity and identity grind) must use this measure so that a key
    /// ground to N bits for one gate passes every other gate regardless of
    /// whether it is presented raw or `ed01`-prefixed. Measuring the
    /// presented string verbatim instead would make the two spellings of the
    /// same key score differently with overwhelming probability.
    public static func keyWorkBits(_ presented: String) -> Int {
        trailingZeroBits(of: canonicalRawHex(presented))
    }

    public static func baseTrust(
        publicKey: String,
        minDifficulty: Int = 0,
        maxDifficulty: Int = 32
    ) -> Double {
        let bits = trailingZeroBits(of: publicKey)
        guard bits > minDifficulty else { return 0 }
        if bits >= maxDifficulty { return 1.0 }
        return Double(bits - minDifficulty) / Double(maxDifficulty - minDifficulty)
    }
}
