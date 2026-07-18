import Foundation
@testable import Tally

actor OneShotBarrier {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(participantCount: Int) {
        precondition(participantCount > 0)
        self.participantCount = participantCount
    }

    func wait() async {
        guard !isOpen else { return }
        if waiters.count == participantCount - 1 {
            isOpen = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

enum ChallengeKnownAnswer {
    static let peer = PeerID(publicKey: "known-answer-peer")
    static let nonce = Data((0..<32).map(UInt8.init))
    // SHA-256(nonce || UTF8(peer) || solution) starts 00008222: exactly 16 zero bits.
    static let validSolution = Data([0x9d, 0x7d, 0, 0, 0, 0, 0, 0])
    static let invalidSolution = Data(repeating: 0, count: 8)

    static func challenge(
        difficulty: Int,
        issuedAt: ContinuousClock.Instant = .now,
        expiresAfter: Duration = .seconds(30)
    ) -> Challenge {
        Challenge(
            nonce: nonce,
            boundPeer: peer,
            difficulty: difficulty,
            issuedAt: issuedAt,
            expiresAfter: expiresAfter
        )
    }
}

struct SeededGenerator {
    private(set) var state: UInt64

    init(defaultSeed: UInt64) {
        let configured = ProcessInfo.processInfo.environment["TALLY_TEST_SEED"]
        if let configured,
           let seed = UInt64(
               configured.hasPrefix("0x") ? String(configured.dropFirst(2)) : configured,
               radix: configured.hasPrefix("0x") ? 16 : 10
           ) {
            self.state = seed
        } else {
            self.state = defaultSeed
        }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

func testNonce(_ value: UInt64) -> Data {
    var encoded = value.littleEndian
    var nonce = Data(repeating: 0, count: 32)
    withUnsafeBytes(of: &encoded) { bytes in
        nonce.replaceSubrange(0..<bytes.count, with: bytes)
    }
    return nonce
}

func invalidSolution(for challenge: Challenge) -> Data {
    var candidate: UInt64 = 0
    while true {
        let solution = testNonce(candidate)
        if !challenge.meetsTarget(solution: solution) { return solution }
        candidate &+= 1
    }
}
