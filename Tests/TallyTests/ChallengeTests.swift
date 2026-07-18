import Testing
import Foundation
@testable import Tally

@Suite("Challenge")
struct ChallengeTests {

    @Test("Challenge with low difficulty is solvable")
    func testSolveLowDifficulty() throws {
        let peer = PeerID(publicKey: "solver")
        let challenge = Challenge(boundPeer: peer, difficulty: 4)
        let solver = ChallengeSolver()
        let solution = try #require(solver.solve(challenge))
        #expect(challenge.verify(solution: solution, peer: peer))
    }

    @Test("Fixed PoW vectors enforce exact and boundary difficulties")
    func knownAnswerVectors() {
        let now = ContinuousClock.now
        let zero = ChallengeKnownAnswer.challenge(difficulty: 0, issuedAt: now)
        let exact = ChallengeKnownAnswer.challenge(difficulty: 16, issuedAt: now)
        let above = ChallengeKnownAnswer.challenge(difficulty: 17, issuedAt: now)
        let maximum = ChallengeKnownAnswer.challenge(difficulty: 256, issuedAt: now)

        #expect(zero.verify(
            solution: ChallengeKnownAnswer.invalidSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        ))
        #expect(exact.verify(
            solution: ChallengeKnownAnswer.validSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        ))
        #expect(!exact.verify(
            solution: ChallengeKnownAnswer.invalidSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        ))
        #expect(!above.verify(
            solution: ChallengeKnownAnswer.validSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        ))
        #expect(!maximum.verify(
            solution: ChallengeKnownAnswer.validSolution,
            peer: ChallengeKnownAnswer.peer,
            at: now
        ))
    }

    @Test("Tally issues and verifies challenge")
    func testTallyChallenge() throws {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "bootstrapper")
        let scoreBefore = tally.admissionScore(for: peer)

        let challenge = tally.issueChallenge(for: peer)
        let solver = ChallengeSolver()
        let solution = try #require(solver.solve(challenge))
        let verified = tally.verifyChallenge(challenge, solution: solution, peer: peer)

        #expect(verified)
        #expect(tally.admissionScore(for: peer) > scoreBefore)
        #expect(tally.peerCount == 1)
        #expect(tally.metrics.challengesIssued == 1)
        #expect(tally.metrics.challengesVerified == 1)
    }

    @Test("Challenge replay is rejected and work is credited once")
    func testChallengeReplayRejected() throws {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "single-use")
        let challenge = tally.issueChallenge(for: peer)
        let solution = try #require(ChallengeSolver().solve(challenge))

        #expect(tally.verifyChallenge(challenge, solution: solution, peer: peer))
        #expect(!tally.verifyChallenge(challenge, solution: solution, peer: peer))
        #expect(tally.metrics.challengesVerified == 1)
    }

    @Test("Challenge bound-peer mismatch is rejected")
    func testChallengeBoundPeerMismatchRejected() throws {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "intended")
        let wrongPeer = PeerID(publicKey: "wrong")
        let challenge = tally.issueChallenge(for: peer)
        let solution = try #require(ChallengeSolver().solve(challenge))

        #expect(!tally.verifyChallenge(challenge, solution: solution, peer: wrongPeer))
        #expect(tally.admissionScore(for: wrongPeer) == 0)
        #expect(tally.peerCount == 0)
        #expect(tally.verifyChallenge(challenge, solution: solution, peer: peer))
    }

    @Test("Failed challenge does not credit peer")
    func testFailedChallenge() {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 16))
        let peer = PeerID(publicKey: "cheat")

        let challenge = tally.issueChallenge(for: peer)
        let verified = tally.verifyChallenge(
            challenge,
            solution: invalidSolution(for: challenge),
            peer: peer
        )

        #expect(!verified)
        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.peerCount == 0)
    }

    @Test("Multiple challenges accumulate")
    func testMultipleChallenges() throws {
        let tally = Tally(config: TallyConfig(
            challengeDifficulty: 4,
            hardnessBaseline: 12
        ))
        let peer = PeerID(publicKey: "worker")
        let solver = ChallengeSolver()
        var scores: [Double] = []

        for _ in 0..<3 {
            let c = tally.issueChallenge(for: peer)
            let solution = try #require(solver.solve(c))
            _ = tally.verifyChallenge(c, solution: solution, peer: peer)
            scores.append(tally.admissionScore(for: peer))
        }

        #expect(scores[0] < scores[1])
        #expect(scores[1] < scores[2])
    }

    @Test("Expired challenge fails verification")
    func testExpiredChallenge() throws {
        let nonce = Data("test-nonce".utf8)
        let peer = PeerID(publicKey: "expiring")
        let valid = Challenge(nonce: nonce, boundPeer: peer, difficulty: 4, expiresAfter: .seconds(300))
        let solver = ChallengeSolver()
        let solution = try #require(solver.solve(valid))

        let expired = Challenge(
            nonce: nonce,
            boundPeer: peer,
            difficulty: 4,
            issuedAt: .now - .seconds(60),
            expiresAfter: .seconds(30)
        )
        #expect(expired.isExpired)
        #expect(expired.verify(solution: solution, peer: peer) == false)
        #expect(solver.solve(expired) == nil)
    }

    @Test("Challenge timestamp tampering is rejected via Tally")
    func challengeTimestampTamperingRejected() throws {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4, challengeExpiration: .seconds(300)))
        let peer = PeerID(publicKey: "slow")
        let challenge = tally.issueChallenge(for: peer)
        let solver = ChallengeSolver()
        let solution = try #require(solver.solve(challenge))

        let alteredChallenge = Challenge(
            nonce: challenge.nonce,
            boundPeer: peer,
            difficulty: challenge.difficulty,
            issuedAt: challenge.issuedAt - .seconds(1),
            expiresAfter: .seconds(300)
        )
        #expect(!alteredChallenge.isExpired)
        let verified = tally.verifyChallenge(alteredChallenge, solution: solution, peer: peer)
        #expect(!verified)
        #expect(tally.admissionScore(for: peer) == 0)
        #expect(tally.peerCount == 0)
    }

    @Test("Non-expired challenge succeeds")
    func testNonExpiredChallenge() throws {
        let peer = PeerID(publicKey: "fresh")
        let challenge = Challenge(boundPeer: peer, difficulty: 4, expiresAfter: .seconds(300))
        #expect(!challenge.isExpired)
        let solver = ChallengeSolver()
        let solution = try #require(solver.solve(challenge))
        #expect(challenge.verify(solution: solution, peer: peer))
    }

    @Test("Verified challenge work raises admission score")
    func testChallengeWorkRaisesAdmissionScore() throws {
        let tally = Tally(config: TallyConfig(challengeDifficulty: 4))
        let peer = PeerID(publicKey: "newbie")
        let solver = ChallengeSolver()

        let scoreBefore = tally.admissionScore(for: peer)
        for _ in 0..<5 {
            let c = tally.issueChallenge(for: peer)
            let solution = try #require(solver.solve(c))
            _ = tally.verifyChallenge(c, solution: solution, peer: peer)
        }
        let scoreAfter = tally.admissionScore(for: peer)

        #expect(scoreAfter > scoreBefore)
    }
}

@Suite("Seeded challenge state machine")
struct SeededChallengeStateMachineTests {
    @Test("Seeded issue, expiry, verification, replay, and reset sequence")
    func seededChallengeOperations() {
        var random = SeededGenerator(defaultSeed: 0xc11a_11e0)
        let seed = random.state
        let config = TallyConfig(
            challengeDifficulty: 0,
            challengeExpiration: .seconds(5),
            maxPeers: 1_000
        )
        var service = ChallengeService(config: config)
        let peers = (0..<4).map { PeerID(publicKey: "challenge-peer-\($0)") }
        var now = ContinuousClock.now
        var history: [Challenge] = []
        var outstanding: [Data: Challenge] = [:]

        for step in 0..<500 {
            now = now.advanced(by: .milliseconds(Int64(random.index(upperBound: 1_500))))
            let operation = random.index(upperBound: 3)

            if operation < 2 {
                outstanding = outstanding.filter { !$0.value.isExpired(at: now) }
            }

            switch operation {
            case 0:
                let peer = peers[random.index(upperBound: peers.count)]
                let challenge = service.issue(
                    for: peer,
                    nonce: testNonce(UInt64(step + 1)),
                    at: now
                )
                history.append(challenge)
                outstanding[challenge.nonce] = challenge

            case 1 where !history.isEmpty:
                let challenge = history[random.index(upperBound: history.count)]
                let submittedPeer = random.index(upperBound: 5) == 0
                    ? peers.first { $0 != challenge.boundPeer }!
                    : challenge.boundPeer
                let expected = outstanding[challenge.nonce] != nil
                    && submittedPeer == challenge.boundPeer
                let accepted = service.verify(
                    challenge,
                    solution: Data(),
                    peer: submittedPeer,
                    at: now
                )
                #expect(accepted == expected, "seed \(seed), step \(step)")
                if accepted {
                    outstanding.removeValue(forKey: challenge.nonce)
                    let replayAccepted = service.verify(
                        challenge,
                        solution: Data(),
                        peer: challenge.boundPeer,
                        at: now
                    )
                    #expect(!replayAccepted, "seed \(seed), replay step \(step)")
                }

            default:
                let peer = peers[random.index(upperBound: peers.count)]
                service.removeChallenges(for: peer)
                outstanding = outstanding.filter { $0.value.boundPeer != peer }
            }

            #expect(service.outstandingCount == outstanding.count, "seed \(seed), step \(step)")
        }
    }
}
