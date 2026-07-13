# Foundational architecture alignment

Tally should measure attributable peer behavior, not absorb every failure observed by its host.

The foundational boundary is:

- remote-attributable malformed, unavailable-after-advertisement, timeout, CID-mismatch, or invalid-evidence behavior may affect the peer ledger;
- local cancellation, overload, storage failure, or unavailable validation inputs must not affect the peer.

`PeerObservation` introduces this typed boundary while preserving the existing low-level API for compatibility. The tests prove that local failures create no ledger and that remote failures, successful responses, latency, and byte accounting retain their intended behavior.

Future Ivy and lattice-node paths should classify failures at the point where attribution is known and call the typed observation API rather than a generic `recordFailure`.
