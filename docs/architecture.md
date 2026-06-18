# Tally Architecture

## Overview

Tally is the reputation and trust substrate that Ivy (the P2P layer under the
Lattice blockchain) calls into to decide *who to serve, how much, and on what
terms*. It answers four questions about a peer, each backed by a small, focused
component:

- **How much do I trust this peer?** — `ReputationScorer` turns observed behavior
  (bytes exchanged, latency, success rate, solved challenges, identity cost) into
  a single score in `[0, 1]`.
- **Should I serve this request right now?** — `AdmissionController` combines a
  per-peer token bucket with global send-rate pressure; under load it defers to
  reputation.
- **Can a stranger earn standing without history?** — `ChallengeService` /
  `Challenge` issue and verify SHA-256 proof-of-work, and `KeyDifficulty` derives
  a floor of trust from the cost of the peer's identity itself.
- **What net balance do two peers owe each other for paid services?** —
  `CreditLine` / `CreditLineLedger` track a signed bilateral balance with a
  PoW-calibrated threshold and graduated debt pressure.

The `Tally` struct is the façade that composes the first three concerns behind a
stable, lock-guarded API. Credit lines are a separate, opt-in actor
(`CreditLineLedger`) for hosts that exchange paid services and settle a net
balance periodically.

```
                         ┌───────────────────────────────────────────┐
   Ivy / host  ───calls──►              Tally (façade)                │
                         │   LockedState<State> (OSAllocatedUnfairLock)│
                         │   ┌───────────────┬────────────────────┐   │
                         │   │ [PeerID:      │  AdmissionController│   │
                         │   │   PeerLedger] │  (token buckets +   │   │
                         │   │  TallyMetrics │   rate window)      │   │
                         │   └──────┬────────┴─────────┬──────────┘   │
                         │          │ score()          │ pressure     │
                         │   ┌──────▼────────┐  ┌───────▼──────────┐   │
                         │   │ReputationScorer│ │ ChallengeService │   │
                         │   └───────────────┘  └──────────────────┘   │
                         └───────────────────────────────────────────┘
                                    │                      │
                          PeerID.trailingZeroBits   Challenge (SHA-256 PoW)

   ── separate, opt-in ──────────────────────────────────────────────
   CreditLineLedger (actor) ── per-peer ──► CreditLine
        threshold ← KeyDifficulty.baseTrust(peer.publicKey)
```

`Tally` is a `struct` whose mutable state lives behind one
`OSAllocatedUnfairLock` (`LockedState` in `Lock.swift`; falls back to `NSLock`
where `os` is unavailable). Every façade method takes the lock for the duration
of one short critical section, so the type is `Sendable` and safe to share. The
write path (`record*`) never decays or scores; decay and reputation are computed
lazily on the read path (`shouldAllow`, `reputation`, `debtRatio`).

## Peer Identity — `PeerID`

A `PeerID` wraps a `publicKey` string and precomputes
`trailingZeroBits`: the number of trailing zero bits in `SHA256(publicKey)`.
That count is the *identity cost* — a peer that ground its key to have more
trailing-zero bits paid more proof-of-work to mint it, and Tally rewards that in
two places: a reputation PoW bonus (below) and the initial credit-line threshold.

`KeyDifficulty` exposes the same primitive standalone:
- `trailingZeroBits(of: publicKey) -> Int` counts trailing-zero bits of
  `SHA256(publicKey)`.
- `canonicalRawHex(_ presented:) -> String` collapses the raw-hex and
  `ed01`-prefixed Multikey spellings of a key onto one canonical string, and
  `keyWorkBits(_ presented:) -> Int` is the single identity-PoW measure —
  `trailingZeroBits(of: canonicalRawHex(presented))`.
- `baseTrust(publicKey:minDifficulty:maxDifficulty:) -> Double` maps the bit
  count linearly onto `[0, 1]`: `0` at/below `minDifficulty`, `1.0` at/above
  `maxDifficulty`, linear in between. This is **Tally's own difficulty concept —
  proof-of-work on peer identity — not a blockchain target.**

## Reputation Score

### Per-peer accounting — `PeerLedger`

Each peer has a `PeerLedger` holding the raw signals:

| Field | Type | Meaning |
|-------|------|---------|
| `bytesSent`, `bytesReceived` | `DecayingCounter` | exchange volume, half-life-decayed |
| `requestCount` | `Int` | requests seen |
| `successCount`, `failureCount` | `Int` | interaction outcomes |
| `challengeHardness` | `Int` | accumulated difficulty of solved challenges |
| `latencyEWMA` | `EWMA` | exponentially weighted mean latency (µs) |
| `firstSeen`, `lastSeen` | `Instant` | timing |

`DecayingCounter` halves its value every `decayHalfLife` seconds
(`value *= exp2(-elapsed / halfLife)`), applied lazily when the ledger is read.
`EWMA` keeps a running mean (`alpha·sample + (1-alpha)·value`) plus count/min/max.
The ledger caches its last score and marks itself stale on any mutation
(`markStale`) or decay, so an unchanged peer scored twice does no recomputation.

### Composing the score — `ReputationScorer`

`ReputationScorer.score(_ ledger:peer:at:)` decays the ledger to `now`, then asks
`PeerLedger.reputation(...)` to blend five weighted factors (weights from
`ReputationWeights`, default in parentheses):

| Factor | Weight | Formula |
|--------|--------|---------|
| Reciprocity | `0.2` | `confidence · 1/(1+debtRatio)`, where `debtRatio = bytesSent/(bytesReceived+1)` |
| Latency | `0.3` | `min(latencyBaseline/(meanLatency+1), 1)`, only once latency is observed |
| Success rate | `0.4` | `outcomeConfidence · max(successRate − failurePenalty, 0)`, where `failurePenalty = failureRate²` |
| Challenges | `0.1` | `min(challengeHardness / hardnessBaseline, 1)` |
| PoW bonus | `0.1` | `confidence · min(peer.trailingZeroBits / powBaseline, 1)` |

`confidence = min((bytesSent+bytesReceived) / exchangeBaseline, 1)` damps both
reciprocity and the identity PoW bonus until a peer has actually exchanged data,
so a fresh peer cannot vault to a high score on volume of zero. Similarly,
`outcomeConfidence = min(successCount + failureCount, 1)` damps the success-rate
factor until at least one outcome is recorded. The first four
factors are summed and clamped to `[0, 1]` (the *behavioral* score); the PoW
bonus is added on top and the total re-clamped to `1.0`. Latency contributes
only when `latencyEWMA.count > 0`; success contributes only when there are
outcomes.

### Distance scaling

`recordSent` / `recordReceived` accept an optional `cpl:` (common-prefix length
between the request key and the peer's DHT address). When present, the bytes
credited to the ledger are scaled by `(256 − clamp(cpl, 0, 256)) / 256`, so work
done for "distant" keys (small CPL) counts more toward reciprocity. The global
rate window always records the *raw* byte count, not the scaled one.

## Rate-Aware Gating — `AdmissionController`

`AdmissionController` owns two pieces of admission state: a per-peer
`RequestTokenBucket` map and a global send-byte window
(`windowBytesSent`, `windowStart`). `Tally.shouldAllow(peer:)` drives it:

1. **Per-peer bucket** — `consumeRequestToken` refills the bucket at
   `perPeerRequestRefillPerSecond` up to `perPeerRequestCapacity` and tries to
   spend one token. A brand-new peer starts with a *full* bucket. No token →
   immediate deny (`metrics.denied++`).
2. **Global pressure** — `ratePressure(at:)` = `currentSendRate /
   rateLimitBytesPerSecond`, clamped to `[0, 2]`, computed from the rolling
   `rateWindow`-second send window (fed by `recordWindowByte` from
   `recordSent`).
3. **Pressure regimes:**
   - `pressure < 0.5` → **allow** unconditionally (capacity to spare).
   - `pressure ≥ 0.5` → score the peer and apply `passesPressureGate`:
     - `0.5 ≤ pressure < 1.0` → require `reputation ≥ (pressure − 0.5)·2`
       (threshold ramps `0 → 1`).
     - `pressure ≥ 1.0` → require `reputation ≥ 0.8`.

The design is **fail-closed under load**: a fresh/unknown peer gets a fresh
bucket but, once global pressure crosses `0.5`, must clear a reputation gate it
has no history to satisfy. When idle, even strangers are served.

## Proof-of-Work Challenges — `Challenge` / `ChallengeService`

`ChallengeService.issue(for:)` mints a `Challenge` bound to a specific peer
(`boundPeer`), carrying a random 32-byte `nonce`, a `difficulty`
(leading-zero-bit target, `challengeDifficulty` default `16`), an `issuedAt`
instant, and `expiresAfter` (`challengeExpiration`, default 30 s). Verification
(`Challenge.verify(solution:peer:)`) rejects expired challenges and challenges
presented for a peer other than `boundPeer`, then checks that
`SHA256(nonce ‖ boundPeer.publicKey ‖ solution)` has at least `difficulty`
leading zero bits. `ChallengeService` also tracks outstanding nonces, consuming
one on a valid solution so a solution can't be replayed. `ChallengeSolver.solve`
is the reference counter-incrementing solver.

`Tally.issueChallenge(for:)` / `verifyChallenge(_:solution:peer:)` wrap this and
keep the bookkeeping: a valid solution adds the challenge's `difficulty` to the
peer's `challengeHardness` (feeding the *Challenges* reputation factor) and bumps
`metrics.challengesVerified`. This is the Sybil-resistance lever — identities are
cheap to mint, but standing for each one costs real computation.

Note the two distinct PoW surfaces: **challenge difficulty** is interactive PoW a
peer performs on demand; **key difficulty** (`PeerID.trailingZeroBits` /
`KeyDifficulty`) is one-time PoW baked into the identity itself.

## Credit Lines — `CreditLine` / `CreditLineLedger`

For peers that exchange *paid* services (relay, retrieval, pinning) and want to
settle a net balance periodically instead of paying per micro-operation, Tally
provides a bilateral credit-line ledger. This is generic infrastructure: Tally
tracks the running balance and signals when settlement is due; *how* and *where*
a balance is actually settled (e.g. an on-chain transfer) is the host's concern.

A `CreditLine` is a value type holding a signed `balance` (`Int64`), a monotonic
`sequence`, a `threshold`, and a `successfulSettlements` count:

- `debtPressure: Double` — continuous `min(|balance|/threshold, 1)`, for graduated
  throttling (higher pressure → less bandwidth allocated).
- `needsSettlement: Bool` — `|balance| ≥ threshold`.
- `availableCapacity: Int64` — `threshold − |balance|`.
- `adjustBalance(by:)` shifts the balance and increments `sequence`.
- `recordSettlement()` zeroes the balance and rescales the threshold by the
  settlement count (more reliable settlers earn larger lines);
  `recordPartialSettlement(workValue:)` pays the balance toward zero;
  `recordMissedSettlement()` halves the threshold.
- `initialThreshold(baseTrust:multiplier:)` derives a line's starting size from a
  peer's identity trust.

`CreditLineLedger` is an **`actor`** keyed by `PeerID` (so all calls are
`await`ed). `establish(with:)` opens a line whose threshold is
`KeyDifficulty.baseTrust(publicKey:minDifficulty:maxDifficulty:) ·
baseThresholdMultiplier` (floored at 1) — **a peer that paid more identity PoW
gets a larger credit extension**. `chargeForRelay`/`earnFromRelay` move the
balance; the host throttles using `debtPressure(for:)` / `needsSettlement(peer:)`,
records outcomes via the `record*Settlement` methods, and observes lines with
`balance(with:)`, `threshold(for:)`, `creditLine(for:)`, and `allLines`.

## Public API Surface

### `Tally` façade

| Method / property | Purpose |
|-------------------|---------|
| `init(config: TallyConfig = .default)` | Construct with tuning. |
| `recordSent(peer:bytes:cpl:)` | Sent bytes → debt + global rate window. |
| `recordReceived(peer:bytes:cpl:)` | Received bytes → credit. |
| `recordRequest(peer:)` | Increment request count. |
| `recordSuccess(peer:)` / `recordFailure(peer:)` | Interaction outcome. |
| `recordLatency(peer:microseconds:)` | Feed latency EWMA. |
| `shouldAllow(peer:) -> Bool` | Token bucket + rate-pressure + reputation gate. |
| `issueChallenge(for:) -> Challenge` | Mint a PoW challenge bound to a peer. |
| `verifyChallenge(_:solution:peer:) -> Bool` | Verify + credit hardness. |
| `reputation(for:) -> Double` | Decay + composite score `[0,1]`. |
| `debtRatio(for:) -> Double` | `bytesSent/(bytesReceived+1)`. |
| `peerLedger(for:) -> PeerLedger?` | Full ledger snapshot. |
| `allPeers() -> [PeerID]` · `peerCount -> Int` | Enumerate / count. |
| `resetPeer(_:)` | Drop a peer's ledger. |
| `ratePressure() -> Double` | Current global pressure `[0,2]`. |
| `metrics -> TallyMetrics` | Aggregate counters. |

### `TallyConfig` (defaults)

| Field | Default | Role |
|-------|---------|------|
| `weights` | `.default` | `ReputationWeights` blend. |
| `latencyBaseline` | `100_000` | µs latency that scores ~1.0. |
| `latencyAlpha` | `0.3` | EWMA smoothing. |
| `decayHalfLife` | `3600` | seconds to halve exchange counters. |
| `challengeDifficulty` | `16` | leading-zero bits required. |
| `challengeExpiration` | `.seconds(30)` | challenge validity. |
| `rateLimitBytesPerSecond` | `10_000_000` | send-rate limit. |
| `rateWindow` | `1.0` | rolling window (s) for pressure. |
| `perPeerRequestCapacity` | `200` | token-bucket size. |
| `perPeerRequestRefillPerSecond` | `50` | token refill rate. |
| `hardnessBaseline` | `160` | challenge-hardness that scores ~1.0. |
| `exchangeBaseline` | `100_000` | bytes for full confidence. |
| `powBaseline` | `16` | key bits for full PoW bonus. |
| `maxPeers` | `nil` | optional cap; sizes the bounded peer-state maps (`maxPeers · 4`, default `4096` when `nil`), evicting the lowest-reputation/LRU peer past capacity. |

`ReputationWeights` fields: `reciprocity 0.2`, `latency 0.3`, `successRate 0.4`,
`challenges 0.1`, `pow 0.1`.

### `TallyMetrics`

`allowed`, `denied`, `totalBytesSent`, `totalBytesReceived`, `challengesIssued`,
`challengesVerified` — all `Int`, `Equatable`.

## How It Composes

In the Lattice/Ivy stack, Tally is the trust layer Ivy consults on the serve
path. A typical request cycle:

1. Ivy receives a peer request → `tally.shouldAllow(peer:)`. Idle nodes serve
   freely; loaded nodes admit only peers whose reputation clears the
   pressure-scaled gate.
2. On serving, Ivy records the exchange (`recordSent`/`recordReceived`, optional
   `cpl`), the outcome (`recordSuccess`/`recordFailure`), and latency — feeding
   the score that gates the *next* request.
3. A stranger with no history bootstraps via `issueChallenge` /
   `verifyChallenge`, and/or starts with a non-zero floor from its key's identity
   PoW.
4. Hosts billing for paid services layer `CreditLineLedger` on top, using
   `debtPressure` for graduated throttling and `needsSettlement` to trigger
   out-of-band settlement.

The block node (`lattice-node`) updates Tally reputation on block acceptance (its
architecture doc lists "Peer reputation updated (Tally)" in the block-acceptance
flow).
