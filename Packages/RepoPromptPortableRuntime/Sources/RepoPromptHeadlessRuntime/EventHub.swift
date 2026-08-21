import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Every host-owned live event consumer must register one of these roles. The
/// hub is the guard: there is no subscription API that can bypass its durable
/// `(storeID, globalSequence)` cursor gate.
public enum ServiceEventConsumerKind: String, CaseIterable, Codable, Sendable {
    case sse
    case portal
    case mcpNotification
    case counter
    case projection
}

public actor ServiceEventHub {
    private struct Subscriber {
        let kind: ServiceEventConsumerKind
        let continuation: AsyncThrowingStream<EventEnvelope, Error>.Continuation
        var gate: EventDeliveryCursorGate
    }

    public struct Snapshot: Sendable, Equatable {
        public let activeSubscribers: Int
        public let activeSubscribersByKind: [ServiceEventConsumerKind: Int]
        public let slowSubscriberTerminations: Int64
        public let lastPublishedCursor: ServiceCursor?
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private let subscriberBufferLimit: Int
    private var slowSubscriberTerminations: Int64 = 0
    private var lastPublishedCursor: ServiceCursor?

    public init(subscriberBufferLimit: Int = 1024) {
        self.subscriberBufferLimit = subscriberBufferLimit
    }

    public func publish(_ event: EventEnvelope) {
        var exhausted: [UUID] = []
        var advanced: [(UUID, Subscriber)] = []
        for (id, var subscriber) in subscribers {
            if let greatest = subscriber.gate.greatestDelivered,
               greatest.storeID != event.storeID
            {
                subscriber.continuation.finish(
                    throwing: ServiceAPIError(
                        code: .cursorExpired,
                        message: "Event store identity changed; obtain a new authoritative snapshot",
                        retryable: false,
                        cursor: greatest
                    )
                )
                exhausted.append(id)
                continue
            }
            var candidate = subscriber.gate
            guard candidate.shouldDeliver(event.cursor) else { continue }
            if case .dropped = subscriber.continuation.yield(event) {
                subscriber.continuation.finish(
                    throwing: ServiceAPIError(
                        code: .rateLimited,
                        message: "Event subscriber fell behind; reconnect from the supplied cursor",
                        retryable: true,
                        cursor: subscriber.gate.greatestDelivered
                    )
                )
                exhausted.append(id)
                slowSubscriberTerminations += 1
            } else {
                subscriber.gate = candidate
                advanced.append((id, subscriber))
            }
        }
        lastPublishedCursor = event.cursor
        for (id, subscriber) in advanced {
            subscribers[id] = subscriber
        }
        for id in exhausted {
            subscribers[id] = nil
        }
    }

    public func subscribe(
        consumer kind: ServiceEventConsumerKind,
        after cursor: ServiceCursor? = nil
    ) -> AsyncThrowingStream<EventEnvelope, Error> {
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(subscriberBufferLimit)) { continuation in
            subscribers[id] = Subscriber(
                kind: kind,
                continuation: continuation,
                gate: EventDeliveryCursorGate(greatestDelivered: cursor)
            )
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            activeSubscribers: subscribers.count,
            activeSubscribersByKind: Dictionary(
                grouping: subscribers.values,
                by: \.kind
            ).mapValues(\.count),
            slowSubscriberTerminations: slowSubscriberTerminations,
            lastPublishedCursor: lastPublishedCursor
        )
    }

    public func finish() {
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
    }
}
