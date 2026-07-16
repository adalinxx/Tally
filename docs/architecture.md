# Tally Architecture

## Boundary

Tally owns:

- peer-global raw byte accounting;
- per-peer token-bucket admission and global send-rate pressure;
- authenticated identity work and peer-bound challenge work;
- protocol violations attributable to a peer; and
- bilateral `CreditLine` accounting.

Tally does not own content availability, route or service health, generic
request success or failure, latency, or DHT/CPL proximity. A host must keep
those observations in the component that understands their semantics.

## Components

```text
Tally
  LockedState
    [PeerID: PeerEvidence]
    AdmissionController
    ChallengeService
    TallyMetrics

CreditLineLedger actor
  [PeerID: CreditLine]
```

`Tally` is a `Sendable` value whose state is protected by
`OSAllocatedUnfairLock` on supported platforms and `NSLock` elsewhere.
`CreditLineLedger` is a separate actor because credit lines have an independent
lifecycle and API.

## Peer Evidence

`PeerEvidence` is internal. It contains exactly four `Double` values and one
`ContinuousClock.Instant`:

| Value | Meaning |
|-------|---------|
| `bytesSent` (`S`) | Raw bytes sent to the peer. |
| `bytesReceived` (`R`) | Raw bytes received from the peer. |
| `protocolViolations` (`V`) | Attributable protocol violations. |
| `challengeWork` (`W`) | Sum of verified challenge difficulty. |
| `lastUpdate` | Shared decay time for all four values. |

Every evidence mutation and every score observation first computes elapsed
seconds and multiplies all four values by:

```text
d = 2^(-elapsed / decayHalfLife)
```

The mutation is applied only after that common decay. This keeps evidence on a
single time basis and prevents a frequently updated field from preserving stale
values in the other fields.

Evidence storage is bounded and evicts least-recently-used entries. Calling
`shouldAllow` for an unknown peer creates request-bucket state but no evidence;
therefore it does not increase `peerCount` or make the peer known to scoring.

## Admission Score

After decay, `PeerEvidence.admissionScore` computes:

```text
C = min((S + R) / exchangeBaseline, 1)
Q = (R + 1) / (S + R + 1)
H = min(W / hardnessBaseline, 1)
K = min(KeyDifficulty.keyWorkBits(peer.publicKey) / powBaseline, 1)

score = clamp((0.50*C*Q + 0.25*H + 0.25*C*K) / (1 + V), 0, 1)
```

An absent evidence entry returns zero. Identity work is multiplied by exchange
confidence, so identity work alone cannot establish a score. Challenge work can
establish at most `0.25` without exchange. A zero violation count adds nothing;
violations only divide evidence already earned.

## Admission Control

`AdmissionController` owns two independent controls:

1. A token bucket per peer. Each `shouldAllow` call consumes one token. Denial
   due to an empty bucket does not alter `PeerEvidence`.
2. A global window of raw bytes sent. `ratePressure` is consumed window bytes
   divided by the configured window byte budget, clamped to `[0, 2]`.

After a token is consumed, `shouldAllow` applies these pressure regimes:

| Pressure | Decision |
|----------|----------|
| `< 0.5` | Allow without observing a score. |
| `>= 0.5` | Require `score >= min((pressure - 0.5) * 1.6, 0.8)`. |

This permits unknown peers while capacity is available and fails closed for
them under pressure.

## Challenges And Identity Work

`ChallengeService` stores a bounded set of outstanding nonces. Each challenge
is bound to a `PeerID`, has a difficulty and expiration, and verifies
`SHA256(nonce || publicKey || solution)` against a leading-zero-bit target. A
valid solution consumes the outstanding nonce before its difficulty is added to
peer evidence. Replays, expired challenges, unknown nonces, and peer mismatches
do not add work.

`KeyDifficulty.keyWorkBits(_:)` canonicalizes raw and `ed01`-prefixed Ed25519
key spellings before measuring trailing zero bits. `PeerID`, lower-level key
difficulty helpers, and `KeyDifficulty.baseTrust` remain public.

## Reset And Metrics

`resetPeer(_:)` removes the peer's evidence, token bucket, and outstanding
challenges. Aggregate metrics are not reset because they describe the lifetime
of the `Tally` instance.

`TallyMetrics` reports allowed and denied admission decisions, total raw bytes
sent and received, and issued and verified challenges.

## Credit Lines

`CreditLine` tracks a signed bilateral balance, sequence, settlement threshold,
and successful settlement count. `CreditLineLedger` serializes a map of lines in
an actor. Identity work calibrates the initial threshold through
`KeyDifficulty.baseTrust`; the host decides when and how actual settlement is
performed.

Credit-line balances do not feed `PeerEvidence` or the admission score.
