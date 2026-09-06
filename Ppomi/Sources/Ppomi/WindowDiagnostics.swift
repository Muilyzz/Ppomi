// Local, opt-in window diagnostics. No titles, content, keyboard input, or unrelated window IDs are recorded.
// Launch with PPOMI_WINDOW_TRACE=1 and redirect stderr to inspect physical-click focus and ordering transitions.
import AppKit
import SwiftUI
import CoreGraphics

enum WindowDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["PPOMI_WINDOW_TRACE"] == "1"
    private static let writeLock = NSLock()
    @MainActor private static var delayedOrdering: [Int: Bool] = [:]

    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        var record = fields
        record["event"] = event
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        writeLock.lock()
        defer { writeLock.unlock() }
        FileHandle.standardError.write(data)
    }

    @MainActor static func panel(_ event: String, _ panel: NSWindow, fields: [String: Any] = [:]) {
        guard enabled else { return }
        var fields = fields
        fields["key"] = panel.isKeyWindow
        fields["main"] = panel.isMainWindow
        fields["active"] = NSApp.isActive
        fields["visible"] = panel.isVisible
        fields["frontBundle"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        log(event, fields)
    }

    static func isMouseBoundary(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return true
        default: return false
        }
    }

    @MainActor static func mouse(_ phase: String, event: NSEvent, panel: NSWindow) {
        guard enabled, isMouseBoundary(event) else { return }
        let content = panel.contentView
        let hit = content?.hitTest(content?.convert(event.locationInWindow, from: nil) ?? .zero)
        var fields: [String: Any] = [
            "mouseType": event.type.rawValue,
            "mouseEvent": event.eventNumber,
            "hitView": hit.map { NSStringFromClass(type(of: $0)) } ?? "none",
            "needsPanelKey": hit?.needsPanelToBecomeKey ?? false,
            "acceptsFirstResponder": hit?.acceptsFirstResponder ?? false,
        ]
        // AppKit invokes this callback before mouseDown. Never query it here: doing so could change the behavior observed.
        if let delayed = delayedOrdering[event.eventNumber] { fields["delayWindowOrdering"] = delayed }
        else { fields["delayWindowOrdering"] = "unobserved" }
        self.panel("mouse.\(phase)", panel, fields: fields)
    }

    @MainActor static func observedDelay(_ delayed: Bool, event: NSEvent, view: NSView) {
        guard enabled else { return }
        if delayedOrdering.count >= 32 { delayedOrdering.removeAll(keepingCapacity: true) }
        delayedOrdering[event.eventNumber] = delayed
        log("mouse.orderingCallback", ["mouseEvent": event.eventNumber,
                                       "view": NSStringFromClass(type(of: view)), "delayWindowOrdering": delayed])
    }
}

/// Only used when tracing is enabled; observes the workbench ordering policy without changing its decision.
final class DiagnosticHostingView<Content: View>: WorkbenchHostingView<Content> {
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        let delayed = super.shouldDelayWindowOrdering(for: event)
        WindowDiagnostics.observedDelay(delayed, event: event, view: self)
        return delayed
    }
}

/// Samples WindowServer outside the main run loop, including while AppKit handles a mouse-down tracking loop.
/// The full list is filtered immediately; only the workbench and Mirroring's windows enter the trace.
final class WindowDiagnosticsSampler {
    private let queue = DispatchQueue(label: "com.muilyzz.ppomi.window-trace", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let panelID: CGWindowID
    private var mirrorPID: pid_t?
    private var previous: Data?

    init(panelID: CGWindowID, mirrorPID: pid_t?) {
        self.panelID = panelID
        self.mirrorPID = mirrorPID
        guard WindowDiagnostics.enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func updateMirrorPID(_ pid: pid_t?) {
        queue.async { [weak self] in self?.mirrorPID = pid }
    }

    private func sample() {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var scoped: [[String: Any]] = []
        var panelIndex: Int?, phoneIndex: Int?
        var largestPhoneArea: CGFloat = -1
        for (index, window) in windows.enumerated() {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  id == panelID || pid == mirrorPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = [bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0]
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            scoped.append(["window": id == panelID ? "panel" : "phone", "id": id,
                           "frame": frame, "layer": layer])
            if id == panelID { panelIndex = index }
            else if layer == 0, frame[2] * frame[3] > largestPhoneArea {
                phoneIndex = index
                largestPhoneArea = frame[2] * frame[3]
            }
        }
        var relativeOrder = "unavailable"
        var foreignBetween = false
        if let panelIndex, let phoneIndex {
            relativeOrder = panelIndex < phoneIndex ? "panelAbovePhone" : "panelBelowPhone"
            let lower = min(panelIndex, phoneIndex), upper = max(panelIndex, phoneIndex)
            if upper > lower + 1 {
                foreignBetween = windows[(lower + 1)..<upper].contains { window in
                    let pid = window[kCGWindowOwnerPID as String] as? pid_t
                    return (window[kCGWindowLayer as String] as? Int) == 0 &&
                        pid != ProcessInfo.processInfo.processIdentifier && pid != mirrorPID
                }
            }
        }
        let state: [String: Any] = ["windows": scoped, "relativeOrder": relativeOrder, "foreignBetween": foreignBetween]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != previous else { return }
        previous = data
        WindowDiagnostics.log("server.changed", state)
    }
}
