# Redesign series dependency

This additive Tally API is consumed by the lattice-node integration branch and is designed for gradual migration. Existing `record*` methods remain source-compatible.

Hosts should classify failures where attribution is known and use `PeerObservation`. The top-level integration tests prove that unavailable validation and local durability failures do not become peer penalties.
