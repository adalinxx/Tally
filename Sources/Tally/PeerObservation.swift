import Foundation

/// Protocol-invalid bytes attributable to the peer that supplied them.
public enum PeerProtocolFailure: Sendable, Equatable {
    case malformedMessage
    case contentAddressMismatch
    case invalidEvidence
}

/// Failures in a peer's content service. A caller should use
/// `advertisedContentUnavailable` only for the peer that advertised the content.
public enum PeerServiceFailure: Sendable, Equatable {
    case advertisedContentUnavailable
    case attributedTimeout
}

/// Failures attributable to a routing peer or relay, not the destination peer.
public enum PeerRouteFailure: Sendable, Equatable {
    case unavailable
    case attributedTimeout
}

/// Local or ambiguous failures that must not affect any peer's reputation.
public enum PeerOperationalFailure: Sendable, Equatable {
    case cancelled
    case overloaded
    case storageUnavailable
    case validationUnavailable
    case ambiguousTimeout
}

/// Independent peer-quality views. None of these determine whether content or
/// evidence is valid; callers use the matching view only to choose whom to ask.
public enum PeerQuality: Sendable, Equatable {
    case protocolCorrectness
    case serviceReliability
    case routeReliability
}

/// A typed observation boundary between a host and Tally.
///
/// The caller classifies an event at the point where attribution is known. Tally
/// records protocol correctness, content service, and routing quality separately;
/// operational failures are intentional no-ops.
public enum PeerObservation: Sendable, Equatable {
    case bytesReceived(Int)
    case bytesSent(Int)
    case serviceSucceeded(latencyMicroseconds: Double? = nil)
    case routeSucceeded(latencyMicroseconds: Double? = nil)
    case protocolFailure(PeerProtocolFailure)
    case serviceFailure(PeerServiceFailure)
    case routeFailure(PeerRouteFailure)
    case operationalFailure(PeerOperationalFailure)
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
        case .serviceSucceeded(let latencyMicroseconds):
            recordServiceSuccess(peer: peer, latencyMicroseconds: latencyMicroseconds)
        case .routeSucceeded(let latencyMicroseconds):
            recordRouteSuccess(peer: peer, latencyMicroseconds: latencyMicroseconds)
        case .protocolFailure:
            recordProtocolFailure(peer: peer)
        case .serviceFailure:
            recordServiceFailure(peer: peer)
        case .routeFailure:
            recordRouteFailure(peer: peer)
        case .operationalFailure:
            break
        }
    }
}
