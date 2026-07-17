# Correctness invariants

These laws define what Tally may conclude from caller-supplied evidence. Tally
does not authenticate peers; attribution is a caller precondition.

## TALLY-001: evidence is peer-global and attributable

Recorded bytes belong to an authenticated peer, and a recorded protocol
violation has cryptographic evidence tying that violation to the charged peer.
Contextual service failure is not peer-global evidence.

## TALLY-002: all evidence shares one time basis

Before any mutation or score observation, sent bytes, received bytes,
violations, and challenge work decay from one timestamp with the configured
half-life. Updating one field cannot preserve stale values in another.

## TALLY-003: absent evidence earns nothing

An unknown peer scores zero. A zero violation count adds no positive term, and
identity work without exchange confidence contributes nothing.

## TALLY-004: byte accounting is total and nontrapping

Nonpositive byte observations are ignored. Aggregate integer counters saturate
instead of wrapping or trapping.

## TALLY-005: request rate is not reputation

Every `shouldAllow` call consumes a per-peer request token before score policy.
Token denial changes admission metrics only; it neither creates evidence nor
records a violation.

## TALLY-006: pressure never makes admission easier

Below pressure `0.5`, a peer with a request token is admitted. At or above
`0.5`, the required score rises monotonically and is capped at `0.8`. Unknown
peers fail once the required score is positive.

## TALLY-007: scoring is bounded

Exchange confidence, reciprocity, challenge work, identity work, violation
discounting, and the final score remain finite and produce a result in `[0, 1]`
for every valid configuration.

## TALLY-008: challenge work is bound and single-use

A challenge is accepted only for its bound peer, exact nonce, difficulty,
expiration, and valid solution. Successful verification consumes the
outstanding nonce before credit, so replay cannot add work twice.

## TALLY-009: identity work has one canonical measure

Admission identity work uses `KeyDifficulty.keyWorkBits(_:)`. Raw Ed25519 hex
and canonical `ed01`-prefixed spellings of the same key measure equally. Tally
does not infer key validity from the work measure.

## TALLY-010: mutable peer state is bounded

Evidence, request buckets, and outstanding challenges have finite capacities
and evict least-recently-used state. Eviction forgets evidence; it does not
create negative evidence.

## TALLY-011: reset has peer scope

`resetPeer(_:)` removes one peer's evidence, request bucket, and outstanding
challenges. It does not alter another peer or rewrite lifetime aggregate
metrics.

## TALLY-012: credit is independent from admission

Credit-line balances, thresholds, and settlement history never affect peer
evidence, global send pressure, or admission score. The host owns service value,
settlement validation, and enforcement.

## TALLY-013: credit arithmetic remains defined

Balance updates saturate at integer bounds, magnitude and capacity clamp before
signed conversion, and nonpositive relay amounts do not mutate a line.

## TALLY-014: Tally grants no application authority

Scores, challenge work, identity work, and credit lines are local resource
policy inputs. They do not prove membership, content validity, storage,
canonicity, consensus rights, or service correctness.

## Verification map

| Area | Primary coverage |
| --- | --- |
| Evidence formula, decay, and absence semantics | `PeerEvidenceTests`, `TallyTests` |
| Token buckets and pressure policy | `AdmissionControllerTests`, `TallyTests` |
| Challenge binding, expiry, and replay | `ChallengeTests`, `AdmissionControllerTests` |
| Bounded peer state and reset | `TallyTests` |
| Credit saturation and service boundary | `CreditLineTests` |
