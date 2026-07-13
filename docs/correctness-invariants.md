# Correctness invariants

## PEER-001 — local failure is not peer failure

Local cancellation, overload, unavailable storage, and unavailable validation inputs do not create or penalize a peer ledger.

Established by: `PeerObservationTests.testLocalFailuresDoNotCreateOrPenalizePeerLedger`.

## PEER-002 — remote invalidity is attributable

A classified remote content-address mismatch or invalid-evidence event increments the peer failure ledger.

Established by: `PeerObservationTests.testRemoteFailureIsAttributedToPeer`.

## PEER-003 — success and latency remain coupled observations

A successful response records one success and its optional latency sample.

Established by: `PeerObservationTests.testSuccessfulResponseRecordsOutcomeAndLatency`.

## PEER-004 — typed observations preserve byte accounting

Positive sent and received observations preserve existing accounting; nonsensical zero or negative values are ignored.

Established by: `PeerObservationTests.testByteObservationsPreserveExistingAccounting`.
