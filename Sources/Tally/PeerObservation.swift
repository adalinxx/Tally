import Foundation

/// Failures attributable to the remote peer or to bytes the peer supplied.
/// These may reduce reputation after the host has established attribution.
public enum PeerRemoteFailure: Sendable, Equatable {
    case timeout
    case advertisedContentUnavailable
    case malformedMessage
    case contentAddressMismatch
    case invalidEvidence
}

/// Failures local to the observing process. They are deliberately represented so
/// callers do not have to collapse them into `recordFailure(peer:)`.
public enum PeerLocalFailure: Sendable, Equatable {
    case cancelled
    case overloaded
    case storageUnavailable
    case validationUnavailable
}

/// A typed observation boundary between a host and Tally.
///
/// The architectural invariant is that local availability and durability failures
/// are not peer behavior. Only explicitly remote-attributable failures affect the
/// peer's failure ledger.
public enum PeerObservation: Sendable, Equatable {
    case bytesReceived(Int)
    case bytesSent(Int)
    case responseSucceeded(latencyMicroseconds: Double? = nil)
    case remoteFailure(PeerRemoteFailure)
    case localFailure(PeerLocalFailure)
}

public extension Tally {
    /// Record one classified observation. Existing low-level `record*` methods remain
    /// available for compatibility, but new integrations should classify failures at
    /// their source and enter through this method.
    func record(_ observation: PeerObservation, for peer: PeerID) {
        switch observation {
        case .bytesReceived(let bytes):
            guard bytes > 0 else { return }
            recordReceived(peer: peer, bytes: bytes)
        case .bytesSent(let bytes):
            guard bytes > 0 else { return }
            recordSent(peer: peer, bytes: bytes)
        case .responseSucceeded(let latencyMicroseconds):
            recordSuccess(peer: peer)
            if let latencyMicroseconds, latencyMicroseconds >= 0 {
                recordLatency(peer: peer, microseconds: latencyMicroseconds)
            }
        case .remoteFailure:
            recordFailure(peer: peer)
        case .localFailure:
            // Local cancellation, overload, unavailable storage, or unavailable
            // validation inputs reveal nothing about the remote peer.
            break
        }
    }
}
