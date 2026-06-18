# Tally

A Bitswap-inspired peer reputation and rate limiting module for Swift. Tracks bytes exchanged, latency, success rate, and proof-of-work challenges to compute a composite reputation score per peer. Under load, only high-reputation peers get served.

```swift
let tally = Tally()
let peer = PeerID(publicKey: "a1f2e3d...")

tally.recordReceived(peer: peer, bytes: 4096)
tally.recordSent(peer: peer, bytes: 2048)
tally.recordLatency(peer: peer, microseconds: 5000)
tally.recordSuccess(peer: peer)

tally.reputation(for: peer)    // 0.72
tally.shouldAllow(peer: peer)  // true — good reputation, under rate limit
```

## How It Works

### Reputation Score

Each peer's reputation is a weighted composite of five factors, clamped to 0.0–1.0:

| Factor | Weight | Measures |
|--------|--------|----------|
| **Reciprocity** | 0.2 | `1 / (1 + debtRatio)` — peers who give back score higher |
| **Latency** | 0.3 | `baseline / (meanLatency + 1)` — fast peers score higher |
| **Success rate** | 0.4 | `successRate − failureRate²` — reliable peers score higher |
| **Challenges** | 0.1 | Proof-of-work completions — bootstrapped peers can earn credit |
| **PoW bonus** | 0.1 | `peer.trailingZeroBits / powBaseline` — costlier identities earn a floor |

The first four factors are summed and clamped to a *behavioral* score; the
identity PoW bonus is added on top. Reciprocity and the PoW bonus are scaled by a
`confidence` factor (`min(totalBytesExchanged / exchangeBaseline, 1)`), so a fresh
peer with no exchange volume can't vault to a high score. See
[docs/architecture.md](docs/architecture.md) for the exact formula.

### Rate-Aware Gating

Instead of a fixed allow/deny threshold, Tally adapts based on current load:

```
ratePressure = currentRate / rateLimitBytesPerSecond

pressure < 0.5  →  allow everyone (plenty of capacity)
pressure 0.5–1.0 →  increasingly selective (reputation must exceed threshold)
pressure >= 1.0  →  only reputation >= 0.8 gets through
```

When you're well under your rate limit, even unknown peers get served. As load climbs, Tally progressively gates to high-reputation peers only.

### Proof of Work Challenges

New peers with no exchange history can bootstrap reputation by solving SHA256 proof-of-work challenges:

```swift
let challenge = tally.issueChallenge(for: peer)
// peer solves: find `solution` where SHA256(nonce || publicKey || solution) has N leading zero bits
let verified = tally.verifyChallenge(challenge, solution: peerSolution, peer: peer)
// verified == true → peer.challengeHardness += difficulty → reputation improves
```

This provides Sybil resistance — creating many identities is cheap, but earning reputation for each requires real computation.

### Credit Lines

Beyond reputation scoring, Tally provides a **bilateral credit-line ledger** for peers that exchange paid services (relay, retrieval, pinning) and want to settle a *net* balance periodically instead of paying per micro-operation. This is generic infrastructure: Tally tracks the running balance and signals when settlement is due; *how* and *where* a net balance is actually settled is the host application's concern.

`CreditLineLedger` is an `actor`, so its methods are `await`ed:

```swift
let ledger = CreditLineLedger(localID: me, baseThresholdMultiplier: 100,
                              minDifficulty: 0, maxDifficulty: 32)

let line = await ledger.establish(with: peer)                  // open a credit line
await ledger.earnFromRelay(peer: peer, amount: 4096)           // peer owes you for service rendered
let ok = await ledger.chargeForRelay(peer: peer, amount: 2048) // consume service; true on success

if await ledger.needsSettlement(peer: peer) {                  // net balance crossed the threshold
    // settle out-of-band (e.g. an on-chain transfer), then:
    await ledger.recordSettlement(peer: peer)
}
await ledger.debtPressure(for: peer)                           // 0.0 (even) … 1.0 (at threshold)
await ledger.balance(with: peer)                               // signed net balance
```

The per-peer **threshold** is calibrated by identity cost via `KeyDifficulty.baseTrust` (a peer that paid more proof-of-work to mint its key earns a larger credit extension), bounded by `[minDifficulty, maxDifficulty]`. The ledger tracks the running balance and exposes `debtPressure(for:)` / `needsSettlement(peer:)` for graduated throttling and settlement triggers; `chargeForRelay` returns `false` only when no line exists, so the host enforces back-pressure by consulting debt pressure before extending more service. Partial and missed settlements (`recordPartialSettlement`, `recordMissedSettlement`) feed settlement reliability back into the line's threshold.

| Method (`CreditLineLedger`) | Description |
|--------|-------------|
| `establish(with:) -> CreditLine` | Open a credit line with a peer. |
| `creditLine(for:) -> CreditLine?` | Current line, if any. |
| `chargeForRelay(peer:amount:) -> Bool` | Consume service against the line; `false` only if no line exists. |
| `earnFromRelay(peer:amount:)` | Credit service rendered to a peer. |
| `needsSettlement(peer:) -> Bool` | Net balance crossed the threshold. |
| `recordSettlement(peer:)` / `recordPartialSettlement(peer:workValue:)` / `recordMissedSettlement(peer:)` | Record settlement outcomes. |
| `debtPressure(for:) -> Double` · `balance(with:) -> Int64` · `threshold(for:) -> UInt64` | Observe a line. |
| `allLines -> [PeerID: CreditLine]` · `removeLine(for:) -> CreditLine?` | Enumerate / close lines. |

## Documentation

- [docs/architecture.md](docs/architecture.md) — the load-bearing concepts grounded
  in code: the reputation score, rate-aware gating, PoW challenges and
  `KeyDifficulty`, credit lines, and how Tally composes as the trust substrate
  Ivy calls into. Includes the full public API surface and a component diagram.

## Requirements

- Swift 6.0+
- macOS 14+ / iOS 17+ / tvOS 17+ / watchOS 10+ / visionOS 1+

## Installation

```swift
.package(url: "https://github.com/adalinxx/Tally.git", from: "1.0.0"),
```

Then add to your target:

```swift
.target(name: "YourTarget", dependencies: ["Tally"])
```

## Usage

### Recording exchanges

```swift
import Tally

let tally = Tally()
let peer = PeerID(publicKey: "a1f2e3d4...")

tally.recordSent(peer: peer, bytes: responseData.count)
tally.recordReceived(peer: peer, bytes: incomingData.count)
tally.recordLatency(peer: peer, microseconds: elapsed)
tally.recordSuccess(peer: peer)
tally.recordFailure(peer: peer)
tally.recordRequest(peer: peer)
```

`recordSent` / `recordReceived` take an optional `cpl:` (common-prefix length)
that distance-scales the bytes credited toward reciprocity — work for "distant"
keys counts more. The global rate window always uses the raw byte count.

### Gating outbound data

```swift
if tally.shouldAllow(peer: peer) {
    let data = fetchData(for: cid)
    tally.recordSent(peer: peer, bytes: data.count)
    send(data, to: peer)
} else {
    sendDenial(to: peer)
}
```

### Proof of work bootstrapping

```swift
// Server side: issue challenge (bound to the requesting peer)
let challenge = tally.issueChallenge(for: peer)
send(challenge, to: peer)

// Client side: solve
let solver = ChallengeSolver()
let solution = solver.solve(challenge)
send(solution, to: server)

// Server side: verify and credit
tally.verifyChallenge(challenge, solution: solution, peer: peer)
```

### Configuration

```swift
let tally = Tally(config: TallyConfig(
    weights: ReputationWeights(
        reciprocity: 0.2,
        latency: 0.3,
        successRate: 0.4,
        challenges: 0.1,
        pow: 0.1
    ),
    latencyBaseline: 100_000,          // microseconds
    decayHalfLife: 3600,               // seconds to halve exchange counters
    challengeDifficulty: 16,           // leading zero bits
    rateLimitBytesPerSecond: 10_000_000,
    rateWindow: 1.0,                   // seconds
    perPeerRequestCapacity: 200,       // token-bucket size
    perPeerRequestRefillPerSecond: 50,
    maxPeers: 10_000
))
```

### Observability

```swift
tally.reputation(for: peer)
tally.debtRatio(for: peer)
tally.peerLedger(for: peer)
tally.ratePressure()

let m = tally.metrics
// m.allowed, m.denied, m.totalBytesSent, m.totalBytesReceived
// m.challengesIssued, m.challengesVerified
```

## API

| Method | Description |
|--------|-------------|
| `recordSent(peer:bytes:cpl:)` | Record bytes sent to a peer (increases debt). |
| `recordReceived(peer:bytes:cpl:)` | Record bytes received from a peer (credits them). |
| `recordLatency(peer:microseconds:)` | Record response latency for a peer. |
| `recordSuccess(peer:)` | Record a successful interaction. |
| `recordFailure(peer:)` | Record a failed interaction. |
| `recordRequest(peer:)` | Increment request count. |
| `shouldAllow(peer:) -> Bool` | Rate-aware + reputation-based allow/deny. |
| `reputation(for:) -> Double` | Composite reputation score (0.0–1.0). |
| `debtRatio(for:) -> Double` | Raw debt ratio for a peer. |
| `ratePressure() -> Double` | Current rate pressure (0.0 = idle, 1.0 = at limit). |
| `issueChallenge(for:) -> Challenge` | Create a proof-of-work challenge bound to a peer. |
| `verifyChallenge(_:solution:peer:) -> Bool` | Verify and credit a solved challenge. |
| `peerLedger(for:) -> PeerLedger?` | Full ledger for a peer. |
| `allPeers() -> [PeerID]` | All tracked peer IDs. |
| `peerCount -> Int` | Number of tracked peers. |
| `resetPeer(_:)` | Remove a peer's ledger. |
| `metrics -> TallyMetrics` | Aggregate stats. |

## Design

- **Lock-based, no actor** — all state behind `OSAllocatedUnfairLock` for nanosecond-scale operations.
- **Bitswap debt ratio** — `r = bytes_sent / (bytes_received + 1)`, same formula as IPFS.
- **Composite reputation** — weighted blend of reciprocity, latency, success rate, solved challenges, and identity proof-of-work.
- **Rate-aware gating** — permissive when idle, selective under load.
- **SHA256 proof of work** — Sybil-resistant reputation bootstrapping for new peers (challenge difficulty), plus a trust floor from identity key difficulty.
- **Bilateral credit lines** — a net-balance ledger with PoW-calibrated thresholds; Tally signals when settlement is due, settlement itself is the host's concern.
- **Minimal dependencies** — Foundation plus swift-crypto (`Crypto`) for SHA-256.

## Performance

Benchmarked on Apple Silicon (M-series), release mode:

| Operation | Time | Notes |
|-----------|------|-------|
| shouldAllow (fresh peer) | **48ns** | Lock + dictionary miss + rate check |
| shouldAllow (known peer) | **69ns** | Lock + lookup + reputation + rate check |
| reputation lookup | **33ns** | Lock + lookup + weighted score |
| recordSent | **89ns** | Lock + lookup + update + rate window |
| recordLatency | **54ns** | Lock + lookup + running stats |
| mixed (80% check / 20% record) | **81ns** | Realistic workload |

## Testing

```bash
swift test
```

74 tests across 7 suites: PeerLedger (debt ratio, reciprocity, success rate, latency scoring, reputation composition, custom weights), Tally (recording, gating, metrics, rate pressure, peer management), AdmissionController (token buckets, rate pressure, pressure gate), Challenge (solving, verification, accumulation, reputation bootstrapping), ChallengeService (issue/verify, expiry, peer binding), ReputationScorer (decay, scoring), and CreditLine (thresholds, settlement, debt pressure).
