# Tally

Local peer-evidence accounting and load-sensitive admission control for Swift.

Tally tracks authenticated bytes, attributable protocol violations, identity
work, and verified interactive challenge work. It combines that evidence with a
per-peer request bucket and process-wide send pressure to answer one question:

```text
Should this process spend resources on this peer right now?
```

Tally does not authenticate peers or interpret a service. The caller must prove
which peer produced an observation before recording it.

## Mental model

```text
authenticated transport
  records bytes and proven protocol violations
                |
                v
Tally
  decayed peer evidence + request bucket + global send pressure
                |
                v
allow or deny this unit of work
```

All state is local and in memory. A score is neither shared reputation nor proof
of application authority.

## Basic use

```swift
import Tally

let tally = Tally()
let peer = PeerID(publicKey: authenticatedPublicKey)

tally.recordReceived(peer: peer, bytes: requestBytes.count)

guard tally.shouldAllow(peer: peer) else {
    return
}

let response = makeResponse()
tally.recordSent(peer: peer, bytes: response.count)
```

Record a violation only after the surrounding protocol can attribute it to the
authenticated peer:

```swift
if signatureIsValid && signedRecordBreaksProtocol {
    tally.recordProtocolViolation(peer: peer)
}
```

Do not record timeouts, unavailable content, failed dials, local queue pressure,
rate-limit denial, latency, DHT distance, or generic request failure as protocol
violations. Their meaning belongs to the service that observed them.

## Evidence

Each peer has four decaying values:

| Symbol | Evidence |
| --- | --- |
| `S` | Raw authenticated bytes sent to the peer. |
| `R` | Raw authenticated bytes received from the peer. |
| `V` | Protocol violations cryptographically attributable to the peer. |
| `W` | Difficulty of verified peer-bound challenges. |

Before any mutation or score observation, all four values decay from one shared
timestamp:

```text
d = 2^(-elapsed / decayHalfLife)
S, R, V, W = d * S, d * R, d * V, d * W
```

The common timestamp prevents frequent traffic in one field from preserving
stale evidence in another.

## Admission score

After decay:

```text
C = min((S + R) / exchangeBaseline, 1)              exchange confidence
Q = (R + 1) / (S + R + 1)                          reciprocity quality
H = min(W / hardnessBaseline, 1)                    challenge work
K = min(keyWork(peer) / powBaseline, 1)             identity work

score = clamp((0.50*C*Q + 0.25*H + 0.25*C*K) / (1 + V), 0, 1)
```

The shape is intentional:

- An unknown peer scores zero.
- No violations is neutral, not positive evidence.
- Identity work earns nothing without exchange confidence.
- Challenge work can bootstrap bounded positive evidence.
- Attributable violations discount evidence already earned.

The score is a local admission input, not a truth claim about the peer.

## Admission decision

`shouldAllow(peer:)` applies two controls in order:

1. Consume one token from that peer's request bucket. An empty bucket denies the
   request without changing peer evidence.
2. Measure process-wide send pressure. Below `0.5`, admit the request. At or
   above `0.5`, require the peer's score to meet a rising threshold.

```text
threshold = min((pressure - 0.5) * 1.6, 0.8)
```

Pressure is the current send-window bytes divided by its configured byte budget,
clamped to `[0, 2]`. Higher pressure can only make admission stricter. This lets
unknown peers bootstrap when capacity is available while reserving scarce work
for peers with evidence under load.

## Interactive proof of work

```swift
let challenge = tally.issueChallenge(for: peer)

// Run brute-force solving away from an event loop or latency-sensitive actor.
if let solution = ChallengeSolver().solve(challenge) {
    let accepted = tally.verifyChallenge(
        challenge,
        solution: solution,
        peer: peer
    )
}
```

Challenges bind a random nonce, peer identity, difficulty, and expiration. A
successful `Tally` verification consumes the outstanding nonce and credits its
work once. Wrong peers, unknown nonces, expired challenges, bad solutions, and
replays earn nothing.

`KeyDifficulty.keyWorkBits(_:)` is the canonical identity-work measure used by
admission scoring and identity-PoW gates. Raw Ed25519 hex and `ed01`-prefixed
Multikey spellings of the same key produce the same result.

## Credit lines

`CreditLine` and `CreditLineLedger` provide optional bilateral accounting. They
are deliberately independent from `Tally` admission evidence.

```swift
let ledger = CreditLineLedger(localID: localPeer)
await ledger.establish(with: peer)

await ledger.earnFromRelay(peer: peer, amount: 4_096)
let pressure = await ledger.debtPressure(for: peer)

if await ledger.needsSettlement(peer: peer) {
    // The host performs and validates settlement.
    await ledger.recordSettlement(peer: peer)
}
```

Tally stores signed balance, sequence, threshold, and settlement history. The
host defines what service creates a charge, what settles it, and whether a line
affects application behavior. Credit balances never feed the admission score.

## Configuration

```swift
let tally = Tally(config: TallyConfig(
    decayHalfLife: 3_600,
    challengeDifficulty: 16,
    challengeExpiration: .seconds(30),
    rateLimitBytesPerSecond: 10_000_000,
    rateWindow: 1,
    perPeerRequestCapacity: 200,
    perPeerRequestRefillPerSecond: 50,
    hardnessBaseline: 160,
    exchangeBaseline: 100_000,
    powBaseline: 16,
    maxPeers: 10_000
))
```

| Setting | Meaning |
| --- | --- |
| `decayHalfLife` | Half-life in seconds for all peer evidence. |
| `challengeDifficulty` | Leading-zero-bit target in `0...256`. |
| `challengeExpiration` | Lifetime of an issued challenge. |
| `rateLimitBytesPerSecond` / `rateWindow` | Process-wide send-window budget. |
| `perPeerRequestCapacity` / `perPeerRequestRefillPerSecond` | Per-peer request bucket. |
| `hardnessBaseline` | Challenge work that saturates `H`. |
| `exchangeBaseline` | Bytes that saturate exchange confidence `C`. |
| `powBaseline` | Identity-work bits that saturate `K`. |
| `maxPeers` | Expected peer scale used to size bounded internal maps; `nil` uses 4,096 entries. |

Configuration is validated with preconditions. Rates, windows, baselines, and
capacities must be finite and positive; request refill may be zero.

## Public surface

| API | Effect |
| --- | --- |
| `recordSent(peer:bytes:)` | Add authenticated sent bytes and global send pressure. |
| `recordReceived(peer:bytes:)` | Add authenticated received bytes. |
| `recordProtocolViolation(peer:)` | Add one caller-proven peer violation. |
| `shouldAllow(peer:)` | Consume a request token and apply pressure-sensitive admission. |
| `admissionScore(for:)` | Observe the peer's decayed score, or zero if unknown. |
| `ratePressure()` | Observe current process-wide send pressure. |
| `issueChallenge(for:)` / `verifyChallenge` | Issue and consume peer-bound challenge work. |
| `resetPeer(_:)` | Remove peer evidence, request-bucket state, and outstanding challenges. |
| `metrics` | Snapshot lifetime byte, admission, and challenge counters. |

## Boundary

| Tally owns | Its caller owns |
| --- | --- |
| Local decayed evidence and admission score | Peer authentication and observation attribution |
| Per-peer request buckets and global send pressure | The resource represented by one admission check |
| Peer-bound challenge issue and replay prevention | Where and when proof of work is required |
| Canonical identity-work measurement | Identity validity and application authority |
| Bilateral credit-line arithmetic | Service pricing, settlement proof, and enforcement |

Content availability, route health, request semantics, latency, topology,
storage, consensus, and canonicity remain outside Tally.

## Documentation

- [Architecture](docs/architecture.md)
- [Correctness invariants](docs/correctness-invariants.md)

## Installation and verification

```swift
.package(url: "https://github.com/adalinxx/Tally.git", from: "3.0.0")
```

Tally requires Swift 6 and depends on `swift-crypto` for SHA-256.

```sh
swift test
swift run -c release TallyBenchmarks
```
