import Foundation
import Observation
import ZulipAPI

public enum PresenceState: Sendable {
    case active
    case idle
    case offline
}

/// User presence, maintained by the periodic ping loop (UpdateMachine): each
/// ping merges the modern-protocol deltas keyed by `last_update_id`.
@MainActor
@Observable
public final class Presence {
    public struct Timestamps: Sendable {
        public var active: Date?
        public var idle: Date?
    }

    public private(set) var info: [Int: Timestamps] = [:]
    public private(set) var lastUpdateId = -1

    func apply(_ result: UpdatePresenceResult) {
        if let updateId = result.presenceLastUpdateId {
            lastUpdateId = updateId
        }
        guard let presences = result.presences else { return }
        for (key, value) in presences {
            guard let userId = Int(key) else { continue }
            info[userId] = Timestamps(
                active: value.activeTimestamp.map { Date(timeIntervalSince1970: Double($0)) },
                idle: value.idleTimestamp.map { Date(timeIntervalSince1970: Double($0)) })
        }
    }

    public func state(of userId: Int, offlineThresholdSeconds: Int) -> PresenceState {
        guard let timestamps = info[userId] else { return .offline }
        let threshold = Double(offlineThresholdSeconds)
        let now = Date.now
        if let active = timestamps.active, now.timeIntervalSince(active) < threshold {
            return .active
        }
        if let idle = timestamps.idle, now.timeIntervalSince(idle) < threshold {
            return .idle
        }
        return .offline
    }
}
