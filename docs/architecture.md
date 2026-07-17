# Architecture

Tally is a process-local evidence and admission component. Its caller supplies
an authenticated `PeerID` and only observations that are meaningful across the
peer's requests. Tally turns those observations into a bounded, decaying score;
it does not discover their meaning itself.

```text
caller
  authenticates peer
  classifies observation
        |
        v
Tally shared state
  peer evidence
  request buckets
  send-pressure window
  challenge registry
  metrics
        |
        v
admission decision

CreditLineLedger actor
  separate bilateral balances
```

## Boundary

Peer-global evidence is an observation whose meaning does not depend on one
content root, route candidate, application object, or local failure mode:

- authenticated bytes sent and received;
- a concrete signed protocol violation;
- canonical identity work; and
- work from a valid peer-bound challenge.

Content misses, timeouts, dial failures, route quality, latency, DHT distance,
and local overload are contextual. They stay with the service that can
interpret them. Tally cannot distinguish a malicious peer from a broken route
or unavailable object unless the caller already has cryptographic evidence.

## Concurrency model

`Tally` is a `Sendable` value backed by shared lock-protected state. Public
methods are synchronous and serialize short evidence, admission, challenge, and
metric mutations in one critical section. Supported Apple platforms use
`OSAllocatedUnfairLock`; other platforms use `NSLock`.

`CreditLineLedger` is a separate actor because bilateral balances have an
independent lifecycle and are never consulted by Tally admission.

## Peer evidence

Each `PeerEvidence` entry contains four `Double` values and one shared
`ContinuousClock.Instant`:

| Value | Meaning |
| --- | --- |
| `bytesSent` (`S`) | Authenticated bytes sent to the peer. |
| `bytesReceived` (`R`) | Authenticated bytes received from the peer. |
| `protocolViolations` (`V`) | Caller-proven attributable violations. |
| `challengeWork` (`W`) | Sum of accepted challenge difficulty. |
| `lastUpdate` | Common decay timestamp. |

Before mutation or scoring, every value is multiplied by:

```text
d = 2^(-elapsed / decayHalfLife)
```

The mutation is applied only after common decay. One frequently updated signal
therefore cannot keep unrelated stale evidence alive.

Nonpositive byte observations are ignored. Aggregate integer metrics saturate
instead of trapping on overflow.

## Score

After decay:

```text
C = min((S + R) / exchangeBaseline, 1)
Q = (R + 1) / (S + R + 1)
H = min(W / hardnessBaseline, 1)
K = min(KeyDifficulty.keyWorkBits(peer.publicKey) / powBaseline, 1)

score = clamp((0.50*C*Q + 0.25*H + 0.25*C*K) / (1 + V), 0, 1)
```

`C` prevents tiny exchanges from looking conclusive. `Q` favors reciprocal
peers rather than peers that only consume output. `H` permits bounded bootstrap
through fresh interactive work. `K` raises the cost of disposable identities
but is multiplied by `C`, so a ground key alone cannot earn admission history.
`V` discounts accumulated positive evidence.

An absent entry scores zero. A zero violation count contributes no positive
term.

## Admission pipeline

`shouldAllow(peer:)` performs one atomic decision:

```text
consume peer request token
        |
        +-- unavailable --> deny
        |
        v
observe global send pressure
        |
        +-- pressure < 0.5 --> allow
        |
        v
score peer and compare with rising threshold
```

The request bucket is independent of evidence. Calling `shouldAllow` for an
unknown peer creates bucket state but not evidence and does not increase
`peerCount`.

The send window contains raw bytes recorded by `recordSent`. Pressure is window
bytes divided by `rateLimitBytesPerSecond * rateWindow`, clamped to `[0, 2]`.
When the window expires, observation resets it to zero.

For pressure at least `0.5`:

```text
required score = min((pressure - 0.5) * 1.6, 0.8)
```

The threshold is monotonic. Unknown peers can bootstrap below pressure `0.5`
and fail closed once positive evidence is required.

Rate denial, whether from the token bucket or score gate, updates decision
metrics only. It does not manufacture a protocol violation.

## Challenges and identity work

`ChallengeService` stores a bounded map of outstanding nonces. Each challenge
binds:

```text
SHA256(nonce || peer public key || solution)
```

to one peer, difficulty, issue time, and expiration. Verification succeeds only
for the outstanding matching challenge and a hash meeting its leading-zero-bit
target. Success removes the nonce before adding difficulty to peer evidence, so
replay cannot earn work twice. Invalid and expired attempts earn nothing.

`KeyDifficulty.keyWorkBits(_:)` hashes the canonical raw Ed25519 key spelling
and counts trailing zero bits. Canonical raw hex and `ed01`-prefixed Multikey
spellings of the same key therefore agree. Key validity remains a caller check.

`ChallengeSolver` is a reference brute-force implementation. It is synchronous
and should not run on an event loop or latency-sensitive actor.

## Bounded state

Peer evidence, request buckets, and outstanding challenges use bounded maps with
least-recently-used eviction. With `maxPeers == nil`, each map holds 4,096
entries. A configured `maxPeers` is multiplied by four to allow related active
state while preserving a finite cap.

Eviction forgets local evidence; it does not declare a peer bad. A later
observation starts a fresh entry.

## Reset and metrics

`resetPeer(_:)` removes that peer's evidence, request bucket, and outstanding
challenges. It does not reset aggregate metrics because metrics describe the
lifetime of the `Tally` instance.

`TallyMetrics` snapshots allowed and denied decisions, raw sent and received
bytes, and issued and verified challenges.

## Credit lines

`CreditLine` holds two peer IDs, a signed saturating balance, monotonic sequence,
settlement threshold, and successful-settlement count. `CreditLineLedger`
serializes a map of lines in an actor.

Positive ledger earnings and negative charges move the balance from the local
host's perspective. Settlement need and debt pressure use the clamped balance
magnitude, so arithmetic remains defined at integer extremes. A successful
settlement clears balance and may grow the threshold; a missed settlement
reduces it.

Identity work calibrates the initial threshold through
`KeyDifficulty.baseTrust`. The host decides what a unit of service is worth,
proves settlement, and chooses how balances affect service. Credit-line state
never enters `PeerEvidence`, global pressure, or the admission score.

## Integration law

An authenticated transport may feed Tally only after it can answer: "Which
cryptographic identity caused this peer-global observation?"

| Observation | Tally | Service-local state |
| --- | --- | --- |
| Authenticated bytes | Record sent/received | Optional route counters |
| Verified signed protocol violation | Record violation | Close or suppress route as needed |
| Empty content response | No violation | Provider availability |
| Timeout or failed dial | No violation | Route health and retry |
| Local rate denial | No violation | Admission metrics already updated |
| Invalid unsigned bytes | No peer attribution | Drop connection/input |

See [correctness-invariants.md](correctness-invariants.md) for the review laws
that enforce this boundary.
