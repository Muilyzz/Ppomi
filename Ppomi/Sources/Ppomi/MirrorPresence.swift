import Foundation

/// A brief missing WindowServer frame is not a reason to tear down an existing dock.
/// Pass monotonic uptime so wall-clock changes cannot extend the grace period.
struct MirrorPresence {
    enum State: Equatable {
        case live, transient, absent
    }

    let gracePeriod: TimeInterval
    private var missingSince: TimeInterval?

    init(gracePeriod: TimeInterval = 0.5) {
        self.gracePeriod = gracePeriod
    }

    mutating func observe(appRunning: Bool, hasLiveWindow: Bool, hasAssociation: Bool,
                          now: TimeInterval) -> State {
        guard appRunning else {
            missingSince = nil
            return .absent
        }
        if hasLiveWindow {
            missingSince = nil
            return .live
        }
        guard hasAssociation else {
            missingSince = nil
            return .absent
        }
        let start = missingSince ?? now
        missingSince = start
        return now - start < gracePeriod ? .transient : .absent
    }
}
