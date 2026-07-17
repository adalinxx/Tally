# Architecture

Tally is process-local policy. Its caller supplies an authenticated `PeerID`
and only evidence that remains meaningful across that peer's requests.

```text
authenticated, attributed observations
                  |
                  v
       evidence + local pressure
                  |
                  v
             allow or deny
```

`Tally` is a `Sendable` value backed by shared lock-protected state. Its public
methods perform short synchronous mutations. `CreditLineLedger` is a separate
actor with an independent lifecycle.

## Evidence

Each peer entry stores sent bytes (`S`), received bytes (`R`), attributable
violations (`V`), challenge work (`W`), and one timestamp. Before mutation or
scoring, every signal decays from that timestamp:

```text
d = 2^(-elapsed / decayHalfLife)
S, R, V, W = d * S, d * R, d * V, d * W
```

One active signal therefore cannot preserve unrelated stale evidence.
Nonpositive byte observations are ignored, and aggregate integer metrics
saturate instead of trapping.

After decay:

```text
C = min((S + R) / exchangeBaseline, 1)
Q = (R + 1) / (S + R + 1)
H = min(W / hardnessBaseline, 1)
K = min(KeyDifficulty.keyWorkBits(peer.publicKey) / powBaseline, 1)

score = clamp((0.50*C*Q + 0.25*H + 0.25*C*K) / (1 + V), 0, 1)
```

`C` requires meaningful exchange, `Q` rewards reciprocity, `H` permits bounded
bootstrap work, and `V` discounts earned evidence. Identity work is multiplied
by `C`, so identity work alone earns no history. An unknown peer scores zero;
the absence of violations is not positive evidence.

## Admission

`shouldAllow(peer:)` is one atomic decision:

1. Consume a token from the peer's request bucket; deny if none is available.
2. Measure current process-wide send pressure.
3. Allow below pressure `0.5`; otherwise require the peer score to reach:

```text
min((pressure - 0.5) * 1.6, 0.8)
```

Pressure is current send-window bytes divided by its configured budget, clamped
to `[0, 2]`. Denial updates metrics only; it does not create evidence or a
protocol violation.

## Challenges and identity work

A challenge binds a random nonce, peer identity, difficulty, and expiration.
Verification accepts only the outstanding matching challenge and a solution
whose hash meets the leading-zero-bit target. Success removes the nonce before
crediting work, preventing replay.

`KeyDifficulty.keyWorkBits(_:)` hashes the canonical raw Ed25519 key and counts
trailing zero bits. Raw hex and canonical `ed01` Multikey spellings therefore
measure equally. Key validity remains a caller concern.

## State lifetime

Evidence, request buckets, and outstanding challenges live in bounded
least-recently-used maps. Eviction forgets local state; it does not condemn a
peer. `resetPeer(_:)` removes one peer's state without rewriting lifetime
metrics.

## Credit lines

`CreditLineLedger` serializes bilateral balances, sequence, thresholds, and
settlement history. Arithmetic saturates at integer bounds. The host defines
service units and validates settlement; credit never enters peer evidence,
send pressure, or the admission score.

## Integration law

Record an observation only after the caller can identify the cryptographic peer
that caused it.

| Observation | Tally action |
| --- | --- |
| Authenticated bytes | Record sent or received bytes |
| Verified signed protocol violation | Record one violation |
| Empty content response, timeout, or failed dial | Keep in service-local state |
| Local rate denial | Record nothing; admission metrics already change |
| Unattributed invalid bytes | Drop the input; charge no peer |

See [Correctness invariants](correctness-invariants.md) for the review laws.
