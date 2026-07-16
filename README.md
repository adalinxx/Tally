# Tally

Tally is a Swift library for peer-global byte accounting, admission control,
proof-of-work identity and challenges, and bilateral credit lines.

Tally deliberately does not track content availability, route or service
health, generic request outcomes, latency, or DHT proximity. Those signals are
owned by the protocols and services that can interpret them correctly.

## Usage

```swift
import Tally

let tally = Tally()
let peer = PeerID(publicKey: "a1f2e3d4...")

tally.recordReceived(peer: peer, bytes: incomingData.count)

if tally.shouldAllow(peer: peer) {
    send(responseData, to: peer)
    tally.recordSent(peer: peer, bytes: responseData.count)
}
```

Only violations of the protocol that are attributable to the peer belong in
the admission evidence:

```swift
tally.recordProtocolViolation(peer: peer)
```

An excessive request rate is handled only by the per-peer token bucket inside
`shouldAllow(peer:)`; it is not recorded as a protocol violation.

## Admission Score

For each peer, Tally keeps four internal decayed values:

- `S`: raw bytes sent
- `R`: raw bytes received
- `V`: attributable protocol violations
- `W`: verified challenge work

All four values share one update time. Before any value is changed or the score
is observed, every value is multiplied by:

```text
d = 2^(-elapsed / decayHalfLife)
```

The admission score is:

```text
C = min((S + R) / exchangeBaseline, 1)
Q = (R + 1) / (S + R + 1)
H = min(W / hardnessBaseline, 1)
K = min(keyWork(peer) / powBaseline, 1)

score = clamp((0.50*C*Q + 0.25*H + 0.25*C*K) / (1 + V), 0, 1)
```

An unknown peer scores zero. The absence of violations contributes no positive
evidence.

`shouldAllow(peer:)` first consumes one token from the peer's request bucket.
If the bucket allows the request, global send-rate pressure controls the score
gate:

```text
pressure < 0.5       allow
pressure >= 0.5      require score >= min((pressure - 0.5) * 1.6, 0.8)
```

## Proof Of Work

Interactive challenges are bound to a peer, expire, and can be verified only
once through `Tally`:

```swift
let challenge = tally.issueChallenge(for: peer)
if let solution = ChallengeSolver().solve(challenge) {
    let accepted = tally.verifyChallenge(challenge, solution: solution, peer: peer)
}
```

A successful verification adds the challenge difficulty to `W`.
`KeyDifficulty.keyWorkBits(_:)` supplies the canonical identity-work measure
used by the score. `KeyDifficulty` also retains its lower-level key difficulty
and base-trust APIs.

## Credit Lines

`CreditLine` and the `CreditLineLedger` actor provide bilateral balance and
settlement accounting independently of admission state:

```swift
let ledger = CreditLineLedger(localID: localPeer)
await ledger.establish(with: peer)
await ledger.earnFromRelay(peer: peer, amount: 4096)

if await ledger.needsSettlement(peer: peer) {
    await ledger.recordSettlement(peer: peer)
}
```

The host owns service policy and settlement execution. Tally only maintains the
line, its balance, threshold, and settlement history.

## Configuration

```swift
let tally = Tally(config: TallyConfig(
    decayHalfLife: 3600,
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

Rates, windows, half-lives, baselines, and capacities must be finite and
positive. Request refill may be zero, and challenge difficulty is `0...256`.

## Tally API

| API | Purpose |
|-----|---------|
| `init(config:)` | Create an instance with admission and challenge tuning. |
| `recordSent(peer:bytes:)` | Record raw bytes sent and feed global rate pressure. |
| `recordReceived(peer:bytes:)` | Record raw bytes received. |
| `recordProtocolViolation(peer:)` | Record one attributable protocol violation. |
| `shouldAllow(peer:) -> Bool` | Apply the request bucket and pressure-sensitive score gate. |
| `admissionScore(for:) -> Double` | Return the peer's decayed score, or zero if unknown. |
| `ratePressure() -> Double` | Return current global send-rate pressure. |
| `resetPeer(_:)` | Remove evidence, request tokens, and outstanding challenges for a peer. |
| `peerCount -> Int` | Number of peers with admission evidence. |
| `metrics -> TallyMetrics` | Snapshot aggregate byte, admission, and challenge counters. |
| `issueChallenge(for:) -> Challenge` | Issue a peer-bound proof-of-work challenge. |
| `verifyChallenge(_:solution:peer:) -> Bool` | Verify one outstanding challenge and credit its work. |

See [docs/architecture.md](docs/architecture.md) for component details. Public
`PeerID`, `Challenge`, `ChallengeSolver`, `KeyDifficulty`, `CreditLine`, and
`CreditLineLedger` APIs are retained alongside the `Tally` facade.

## Installation

```swift
.package(url: "https://github.com/adalinxx/Tally.git", from: "3.0.0")
```

Tally requires Swift 6.0 and depends on `swift-crypto` for SHA-256.

## Verification

```bash
swift test
swift run -c release TallyBenchmarks
```
