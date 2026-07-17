# Correctness invariants

Tally does not authenticate peers. Every recorded observation is already
attributed by its caller.

| ID | Law |
| --- | --- |
| TALLY-001 | Evidence is peer-global; violations are cryptographically attributable. |
| TALLY-002 | Every evidence field decays from one shared timestamp before mutation or scoring. |
| TALLY-003 | Unknown peers score zero; absence of violations and unexchanged identity work earn nothing. |
| TALLY-004 | Nonpositive byte observations are ignored and aggregate counters saturate. |
| TALLY-005 | Request-token denial changes metrics, not evidence or reputation. |
| TALLY-006 | Greater send pressure never lowers the admission threshold. |
| TALLY-007 | Every score component and the final score remain finite and bounded. |
| TALLY-008 | Challenges are peer-bound, exact, expiring, and consumed before work is credited. |
| TALLY-009 | Admission and identity gates use the same canonical key-work measure. |
| TALLY-010 | Mutable peer-associated state retained by `Tally` is bounded: evidence, request buckets, and outstanding challenges; eviction forgets rather than punishes. |
| TALLY-011 | Peer reset affects only that peer and preserves lifetime metrics. |
| TALLY-012 | Credit state never affects evidence, pressure, or admission score. |
| TALLY-013 | Credit arithmetic saturates; successful settlement recovers zero without lowering the threshold; nonpositive relay amounts do not mutate state. |
| TALLY-014 | Tally grants no membership, content, storage, consensus, or application authority. |

Coverage lives in `PeerEvidenceTests`, `TallyTests`, `AdmissionControllerTests`,
`ChallengeTests`, and `CreditLineTests`.
