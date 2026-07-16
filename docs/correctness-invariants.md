# Correctness invariants

## PEER-001 — operational failure is not peer failure

Local cancellation, overload, unavailable storage, and unavailable validation inputs do not create or penalize a peer ledger.

Established by: `PeerObservationTests.testOperationalFailuresDoNotCreateOrPenalizePeerLedger`.

## PEER-002 — attribution categories remain distinct

Protocol, service, and route failures increment separate counters even while contributing to the compatibility aggregate.

Established by: `PeerObservationTests.testFailureCategoriesRemainDistinct`.

## PEER-003 — success and latency remain coupled observations

A successful response records one success and its optional latency sample.

Established by: `PeerObservationTests.testSuccessfulServiceRecordsOutcomeAndLatency`.

## PEER-004 — typed observations preserve byte accounting

Positive sent and received observations preserve existing accounting; nonsensical zero or negative values are ignored.

Established by: `PeerObservationTests.testByteObservationsPreserveExistingAccounting`.

## PEER-005 — invalid latency is not telemetry

Negative, NaN, and infinite latency samples do not enter the EWMA.

Established by: `PeerObservationTests.testInvalidLatencySamplesAreIgnored`.
