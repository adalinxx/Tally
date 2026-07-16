# Foundational architecture alignment

Tally should measure attributable peer behavior, not absorb every failure observed by its host.

The boundary is:

- protocol-invalid bytes affect protocol correctness;
- advertised-but-unserved content affects service reliability only for its advertiser;
- relay and route failures affect the routing peer, not the destination;
- local cancellation, overload, storage failure, unavailable validation inputs, and ambiguous timeouts do not affect a peer.

`PeerObservation` preserves those categories in separate decaying counters. The legacy aggregate outcome counters remain for source compatibility and scoring, but callers can choose peers using the category that matches the operation.

Availability quality can influence whom a node asks next. It never decides whether supplied evidence satisfies a protocol.
