import Foundation

public enum RemoteEventReplayResult: Sendable, Equatable {
    case events([RemoteEvent])
    case snapshotRequired
}

/// Bounded, in-memory event history for a single desktop instance.
///
/// The gateway owns one buffer and uses it for reconnects. If a mobile cursor is
/// older than the retained range, the caller must send a complete authoritative
/// snapshot before resuming live events.
public actor RemoteEventReplayBuffer {
    public let capacity: Int
    private var events: [RemoteEvent] = []
    private var eventIDs: Set<UUID> = []
    private var nextSequence: UInt64 = 1

    public init(capacity: Int = 512) {
        precondition(capacity > 0, "Remote event replay capacity must be positive")
        self.capacity = capacity
    }

    @discardableResult
    public func append(_ event: RemoteEvent) -> RemoteEvent {
        guard !eventIDs.contains(event.eventID) else {
            return events.first(where: { $0.eventID == event.eventID }) ?? event
        }

        let sequenced = event.assigning(sequence: nextSequence)
        nextSequence += 1
        events.append(sequenced)
        eventIDs.insert(sequenced.eventID)

        if events.count > capacity {
            let removeCount = events.count - capacity
            for _ in 0 ..< removeCount {
                let event = events.removeFirst()
                eventIDs.remove(event.eventID)
            }
        }
        return sequenced
    }

    public func replay(
        after cursor: UInt64?,
        desktopInstanceID: String
    ) -> RemoteEventReplayResult {
        guard let cursor else { return .events(events) }
        guard let first = events.first else { return .events([]) }
        guard cursor >= first.sequence - 1 else { return .snapshotRequired }

        return .events(events.filter {
            $0.desktopInstanceID == desktopInstanceID && $0.sequence > cursor
        })
    }

    public func latestCursor() -> UInt64 {
        events.last?.sequence ?? 0
    }

    public func removeAll() {
        events.removeAll(keepingCapacity: true)
        eventIDs.removeAll(keepingCapacity: true)
    }
}
