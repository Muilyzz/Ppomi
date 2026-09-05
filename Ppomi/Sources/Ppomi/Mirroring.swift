// iPhone Mirroring ("iPhone 미러링", com.apple.ScreenContinuity) seen through CGWindowList and accessibility: find the window,
// move it, read the overlay state, press the reconnect button. Ported from phone.swift (the tested CLI); the CLI's fail() became
// a log line, so every call survives a missing window or a missing Accessibility grant.
import AppKit
import ApplicationServices

enum Mirroring {
    static let bundleID = "com.apple.ScreenContinuity"
    static let defaultSize = CGSize(width: 348, height: 766)      // the window's usual size, for when there is no window to measure

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// The Accessibility grant, logged instead of the CLI's fail().
    @discardableResult
    static func trusted(_ what: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        print("Mirroring.\(what): Accessibility 권한 필요 (시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용)")
        return false
    }

    // MARK: windows

    /// On-screen layer-0 windows of the mirroring app, largest first. CG coords (origin top-left of the main display).
    /// CGWindowList sometimes reports a bogus 37x119 frame for the live window (mid-animation), so callers that only need
    /// the ID must not filter on size.
    private static func cgWindows() -> [(id: CGWindowID, rect: CGRect)] {
        guard let pid = app()?.processIdentifier else { return [] }
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w -> (id: CGWindowID, rect: CGRect)? in
            guard (w["kCGWindowOwnerPID"] as? pid_t) == pid, (w["kCGWindowLayer"] as? Int) == 0,
                  let b = w["kCGWindowBounds"] as? [String: CGFloat], let id = w["kCGWindowNumber"] as? Int,
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"] else { return nil }
            return (CGWindowID(id), CGRect(x: x, y: y, width: width, height: height))
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
    }
    static func windows() -> [CGRect] { cgWindows().map(\.rect) }
    static func windowID() -> CGWindowID? { cgWindows().first?.id }       // for screencapture -l
    /// The live window (taller than a Stage Manager thumbnail) with its id, for docking and z-ordering against it.
    static func liveWindow() -> (id: CGWindowID, rect: CGRect)? { cgWindows().first { $0.rect.height > 200 } }

    /// One AX attribute, nil when missing.
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// The largest AX window (taller than 200: not a thumbnail) with its frame — the same "largest" rule as windows(),
    /// so capture/tap/place all agree on one window.
    static func axWindowAndFrame() -> (AXUIElement, CGRect)? {
        guard let pid = app()?.processIdentifier,
              let wins = attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, CGRect)?
        for w in wins {
            var p = CGPoint.zero, s = CGSize.zero
            guard let pos = attr(w, kAXPositionAttribute), let size = attr(w, kAXSizeAttribute),
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
                  s.height > 200 else { continue }
            if s.width * s.height > (best?.1.width ?? 0) * (best?.1.height ?? 0) { best = (w, CGRect(origin: p, size: s)) }
        }
        return best
    }
    static func axWindow() -> AXUIElement? { axWindowAndFrame()?.0 }
    static func axFrame() -> CGRect? { axWindowAndFrame()?.1 }

    // MARK: placement

    /// The screen a CG rect lies on (AppKit screens have a bottom-left origin; CG has top-left of the main display).
    static func screen(containing rect: CGRect) -> NSScreen? {
        let main = NSScreen.screens.first?.frame ?? .zero
        return NSScreen.screens.first(where: { sc in
            CGRect(x: sc.frame.minX, y: main.maxY - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height).intersects(rect)
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The one reference position for the mirroring window, shared by collection (am.py `phone place center`) and the kiosk:
    /// the centre of the screen the window is on. CG coords, which is what the AX position takes.
    static func homePoint() -> CGPoint {
        let rect = windows().first ?? CGRect(origin: .zero, size: defaultSize)
        let main = NSScreen.screens.first?.frame ?? .zero
        guard let s = screen(containing: rect) else { return rect.origin }
        return CGPoint(x: s.frame.minX + (s.frame.width - rect.width) / 2,
                       y: (main.maxY - s.frame.maxY) + (s.frame.height - rect.height) / 2)
    }

    /// Move the mirroring window (AX position, CG coords). Sleeps 0.3 s so the CG window list reflects the move.
    static func place(_ p: CGPoint) {
        guard trusted("place") else { return }
        guard let w = axWindow() else { print("Mirroring.place: no AX window"); return }
        var pt = p
        if let v = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        usleep(300_000)
    }

    /// Bring the mirroring app to the front (AX frontmost; NSRunningApplication.activate is unreliable for it).
    /// `wait` blocks up to 2 s until it really is frontmost — needed before posting input, not for the kiosk's pin.
    static func activate(wait: Bool = false) {
        guard trusted("activate"), let app = app() else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard wait else { return }
        for _ in 0..<20 {
            if (attr(ax, kAXFrontmostAttribute) as? Bool) == true { usleep(150_000); return }
            usleep(100_000)
        }
        print("Mirroring.activate: could not bring iPhone Mirroring to front")
    }

    /// Pull the mirroring window out of a Stage Manager thumbnail and wait until AX sees a real frame (height > 200).
    @discardableResult
    static func stage(timeout: TimeInterval = 2) -> Bool {
        guard app() != nil else { return false }
        activate(wait: true)
        let steps = max(1, Int(timeout / 0.1))
        for i in 0...steps {
            if let f = axFrame(), f.height > 200 { return true }
            if i < steps { usleep(100_000) }
        }
        return false
    }

    // MARK: state, read from the window's accessibility tree

    /// Every value/title/description under `e` (depth ≤ 6). The overlay texts ("연결이 중단됨", "iPhone 사용 중") live here.
    private static func texts(_ e: AXUIElement, depth: Int = 0, into out: inout [String]) {
        for a in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let t = attr(e, a) as? String, !t.isEmpty { out.append(t) }
        }
        guard depth < 6 else { return }
        for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { texts(k, depth: depth + 1, into: &out) }
    }

    static func state() -> MirrorState {
        guard let w = axWindow() else { return .none }
        var ts: [String] = []
        texts(w, into: &ts)
        return classify(ts)
    }

    /// The overlay texts → state. Pure, so it can be checked without a window.
    static func classify(_ ts: [String]) -> MirrorState {
        let all = ts.joined(separator: " ")
        if all.contains("사용 중") || all.contains("잠그십시오") { return .inUse }
        if all.contains("중단됨") || all.contains("다시 시도") { return .disconnected }
        if all.contains("일시 정지") || ts.contains("재개") { return .paused }
        return .connected
    }

    /// Press the overlay's 다시 시도 (disconnected) or 재개 (paused) button. False when there is none to press.
    @discardableResult
    static func reconnect() -> Bool {
        guard trusted("reconnect"), let w = axWindow() else { return false }
        func button(in e: AXUIElement, depth: Int) -> AXUIElement? {
            if attr(e, kAXRoleAttribute) as? String == kAXButtonRole,
               [attr(e, kAXTitleAttribute), attr(e, kAXDescriptionAttribute)].contains(where: {
                   guard let t = $0 as? String else { return false }
                   return t.contains("다시 시도") || t.contains("재개") }) { return e }
            guard depth < 8 else { return nil }
            for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let b = button(in: k, depth: depth + 1) { return b } }
            return nil
        }
        guard let b = button(in: w, depth: 0) else { print("Mirroring.reconnect: no 다시 시도/재개 button"); return false }
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }
}

/// Turns the mirroring window's accessibility events into state changes, with a 5 s poll as belt and braces (some transitions
/// raise no AX event) and to pick the app up when it launches later. Main thread only; onChange fires only on a change.
@MainActor
final class MirrorWatcher {
    var onChange: (MirrorState) -> Void
    private(set) var last: MirrorState = .none
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: Timer?
    private var checkPending = false
    private var warned = false

    init(onChange: @escaping (MirrorState) -> Void) { self.onChange = onChange }
    deinit { if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) } }

    func start() {
        stop()
        let t = Timer(timeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { self.attach(); self.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        attach(); check()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        detach()
    }

    /// (Re)attach the AXObserver when the mirroring app is running and is not the process we already observe.
    private func attach() {
        guard let app = Mirroring.app() else { detach(); return }
        if observer != nil, app.processIdentifier == observedPID { return }
        detach()
        guard AXIsProcessTrusted() else {
            if !warned { warned = true; Mirroring.trusted("watch") }
            return
        }
        var obs: AXObserver?
        let made = AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            MainActor.assumeIsolated { Unmanaged<MirrorWatcher>.fromOpaque(refcon).takeUnretainedValue().scheduleCheck() }
        }, &obs)
        guard made == .success, let o = obs else { print("MirrorWatcher: AXObserverCreate failed (\(made.rawValue))"); return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXLayoutChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification,
                  kAXCreatedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(o, ax, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observer = o; observedPID = app.processIdentifier
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observer = nil; observedPID = 0
    }

    /// AX events come in bursts; walk the tree once per burst.
    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self.checkPending = false; self.check() } }
    }

    private var lastRetry = Date.distantPast

    private func check() {
        let s = Mirroring.state()
        // 연결이 중단됨 / 일시 정지됨: press the button ourselves, every 20 s, until the phone is back. Waiting is the same thing.
        if s == .disconnected || s == .paused, Date().timeIntervalSince(lastRetry) > 20 { lastRetry = Date(); Mirroring.reconnect() }
        guard s != last else { return }
        last = s
        onChange(s)
    }
}
