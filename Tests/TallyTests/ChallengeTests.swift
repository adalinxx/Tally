import Testing
import Foundation
@testable import Tally

@Suite("Challenge")
struct ChallengeTests {

    @Test("Challenge with low difficulty is solvable")
    func testSolveLowDifficulty() {
        let peer = PeerID(publicKey: "solver")
        let challenge = Challenge(boundPeer: peer, difficulty: 4)
        let solver = ChallengeSolver()
        let solution = solver.solve(challenge)
        #expect(challenge.verify(solution: solution, peer: peer))
    }

    @Test("Wrong solution fails verification")
    func testWrongSolution() {
        let peer = PeerID(publicKey: "solver")
        let challenge = Challenge(boundPeer: peer, difficulty: 16)
        let badSolution = Data("not-a-solution".utf8)
        #expect(challenge.verify(solution: badSolution, peer: peer) == false)
    }

    @Test("Tally issues and verifies challenge")
    func testTallyChallenge() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "bootstrapper")

        let challenge = tally.issueChallenge(for: peer)
        let solver = ChallengeSolver()
        let solution = solver.solve(challenge)
        let verified = tally.verifyChallenge(challenge, solution: solution, peer: peer)

        #expect(verified)
        #expect(tally.peerLedger(for: peer)?.challengeHardness.value == 4)
        #expect(tally.metrics.challengesIssued == 1)
        #expect(tally.metrics.challengesVerified == 1)
    }

    @Test("Challenge replay is rejected and hardness is credited once")
    func testChallengeReplayRejected() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "single-use")
        let challenge = tally.issueChallenge(for: peer)
        let solution = ChallengeSolver().solve(challenge)

        #expect(tally.verifyChallenge(challenge, solution: solution, peer: peer))
        #expect(!tally.verifyChallenge(challenge, solution: solution, peer: peer))
        #expect(tally.peerLedger(for: peer)?.challengeHardness.value == 4)
        #expect(tally.metrics.challengesVerified == 1)
    }

    @Test("Challenge bound-peer mismatch is rejected")
    func testChallengeBoundPeerMismatchRejected() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "intended")
        let wrongPeer = PeerID(publicKey: "wrong")
        let challenge = tally.issueChallenge(for: peer)
        let solution = ChallengeSolver().solve(challenge)

        #expect(!tally.verifyChallenge(challenge, solution: solution, peer: wrongPeer))
        #expect(tally.peerLedger(for: wrongPeer) == nil)
        #expect(tally.verifyChallenge(challenge, solution: solution, peer: peer))
    }

    @Test("Failed challenge does not credit peer")
    func testFailedChallenge() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 16))
        let peer = PeerID(publicKey: "cheat")

        let challenge = tally.issueChallenge(for: peer)
        let verified = tally.verifyChallenge(challenge, solution: Data("bad".utf8), peer: peer)

        #expect(!verified)
        #expect(tally.peerLedger(for: peer) == nil)
    }

    @Test("Multiple challenges accumulate")
    func testMultipleChallenges() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "worker")
        let solver = ChallengeSolver()

        for _ in 0..<3 {
            let c = tally.issueChallenge(for: peer)
            _ = tally.verifyChallenge(c, solution: solver.solve(c), peer: peer)
        }

        #expect(tally.peerLedger(for: peer)?.challengeHardness.value == 12)
        #expect(tally.reputation(for: peer) > 0)
    }

    @Test("Expired challenge fails verification")
    func testExpiredChallenge() {
        let nonce = Data("test-nonce".utf8)
        let peer = PeerID(publicKey: "expiring")
        let valid = Challenge(nonce: nonce, boundPeer: peer, difficulty: 4, expiresAfter: .seconds(300))
        let solver = ChallengeSolver()
        let solution = solver.solve(valid)

        let expired = Challenge(
            nonce: nonce,
            boundPeer: peer,
            difficulty: 4,
            issuedAt: .now - .seconds(60),
            expiresAfter: .seconds(30)
        )
        #expect(expired.isExpired)
        #expect(expired.verify(solution: solution, peer: peer) == false)
    }

    @Test("Expired challenge not credited via Tally")
    func testExpiredChallengeNotCredited() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4, challengeExpiration: .seconds(300)))
        let peer = PeerID(publicKey: "slow")
        let challenge = tally.issueChallenge(for: peer)
        let solver = ChallengeSolver()
        let solution = solver.solve(challenge)

        let expiredChallenge = Challenge(
            nonce: challenge.nonce,
            boundPeer: peer,
            difficulty: challenge.difficulty,
            issuedAt: .now - .seconds(600),
            expiresAfter: .seconds(300)
        )
        let verified = tally.verifyChallenge(expiredChallenge, solution: solution, peer: peer)
        #expect(!verified)
        #expect(tally.peerLedger(for: peer) == nil)
    }

    @Test("Non-expired challenge succeeds")
    func testNonExpiredChallenge() {
        let peer = PeerID(publicKey: "fresh")
        let challenge = Challenge(boundPeer: peer, difficulty: 4, expiresAfter: .seconds(300))
        #expect(!challenge.isExpired)
        let solver = ChallengeSolver()
        let solution = solver.solve(challenge)
        #expect(challenge.verify(solution: solution, peer: peer))
    }

    @Test("Challenges boost reputation for bootstrapped peer")
    func testChallengeBoostsReputation() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "newbie")
        let solver = ChallengeSolver()

        let repBefore = tally.reputation(for: peer)
        for _ in 0..<5 {
            let c = tally.issueChallenge(for: peer)
            _ = tally.verifyChallenge(c, solution: solver.solve(c), peer: peer)
        }
        let repAfter = tally.reputation(for: peer)

        #expect(repAfter > repBefore)
    }
}
