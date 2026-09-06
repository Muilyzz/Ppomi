import CoreGraphics

/// WindowServer order is front-to-back. Ppomi can sit above the phone temporarily while revealing the pair;
/// another application's normal window in front means the phone is still buried.
enum MirroringOrder {
    struct Window {
        let id: CGWindowID
        let owner: pid_t
        let layer: Int
    }

    static func isInFront(phoneID: CGWindowID, phonePID: pid_t, ppomiPID: pid_t,
                          windows: [Window]) -> Bool {
        for window in windows {
            if window.id == phoneID, window.owner == phonePID, window.layer == 0 { return true }
            if window.layer == 0, window.owner != phonePID, window.owner != ppomiPID { return false }
        }
        return false
    }
}
