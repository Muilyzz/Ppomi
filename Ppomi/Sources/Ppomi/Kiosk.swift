// The kiosk ("donut"): four black panels above everything (menu bar and Dock included) leave a hole at Mirroring.homePoint()
// and the mirroring window is pinned into it. We control where the window goes, so the hole is fixed and anything that moves
// the window gets undone; only a size change (View > 크게/작게) rebuilds the hole. The mirroring window stays a normal window
// inside the hole and gets clicks and keys as usual; the mirroring app is kept frontmost so no other window can wander in.
// The left band hosts the workbench; the bottom band carries the phone band (caption, ask buttons) and the rim around the
// hole takes the phase's color (gold = 뽀미 has the phone, white = your turn, faint = idle). Leave: a mouse click on the
// ring only reveals × (top-right corner, with its hint); only that mark turns the kiosk off. Esc reveals ×, a second Esc
// leaves. Ported from phone.swift's Ring, driven by AppState.donut.
// Off the kiosk the same topology is the 뽀미 window: a titled, non-activating panel (MainWindow inside) that joins every
// app's stage, so it stays beside the phone under Stage Manager and clicking it never parks the phone; dock() keeps the
// phone over the panel's dock pane and just above the panel.
//
// Stage Manager / click-through: a regular NSWindow is staged and can exist in CGWindowList while not being drawn or hit-tested,
// so clicks land on whatever is behind (the Stage Manager strip, Finder, the Dock). Apple's overlay recipe is an .accessory
// app + NSPanel(.nonactivatingPanel) + collectionBehavior including .canJoinAllApplications. A CGEvent tap is the backstop:
// a click on the ring that would miss our panels is swallowed instead of passing through.
//
// Do not set .canJoinAllSpaces: a 3-finger space swipe would take the donut to the next desktop while the mirroring
// window stays behind — a frame with an empty hole. Gestures (swipe/pinch/Mission Control) are swallowed for the same reason.
import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// One black band. Draws the rim on the side facing the hole — the top/bottom bands only across `rimSpan` (the hole's
/// x range), so the four lines frame the phone — in the phase's color and weight; reports clicks. The panel never
/// becomes key, so keyboard focus stays with the mirroring window.
final class RingView: NSView {
    var edge: NSRectEdge = .minY                           // the side of this band that faces the hole
    var onPress: () -> Void = {}
    var rimSpan: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }
    var phase: Phase = .idle { didSet { if oldValue != phase { needsDisplay = true } } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let (c, t): (NSColor, CGFloat) = switch phase {
        case .agent: (NSColor(red: 0.78, green: 0.64, blue: 0, alpha: 1), 2)      // 뽀미 has the phone
        case .humanTurn: (NSColor(white: 1, alpha: 0.9), 1)                       // your turn
        default: (NSColor(white: 1, alpha: 0.25), 1)                              // idle · in hand · disconnected
        }
        c.setFill()
        let b = bounds, x0 = rimSpan?.lowerBound ?? 0, w = rimSpan.map { $0.upperBound - $0.lowerBound } ?? b.width
        switch edge {
        case .minY: NSRect(x: x0, y: 0, width: w, height: t).fill()
        case .maxY: NSRect(x: x0, y: b.height - t, width: w, height: t).fill()
        case .minX: NSRect(x: 0, y: 0, width: t, height: b.height).fill()
        default:    NSRect(x: b.width - t, y: 0, width: t, height: b.height).fill()
        }
    }
}

/// Overlay panel: does not activate us (so Stage Manager / full screen of the mirroring app stay put), does not hide
/// when iPhone Mirroring is frontmost, and joins every app's stage so it is still drawn and hit-tested.
/// Keep the workbench immediately below the phone when it is raised, including ordering requests outside orderFront.
/// Both stay at normal level so other applications cannot permanently cover the workbench.
final class MainPanel: NSPanel {
    var phoneID: CGWindowID?
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .above, let p = phoneID { super.order(.below, relativeTo: Int(p)) }
        else { super.order(place, relativeTo: otherWin) }
    }
    override func orderFront(_ sender: Any?) {
        if let p = phoneID { order(.below, relativeTo: Int(p)) } else { super.orderFront(sender) }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) { makeKey(); orderFront(sender) }
    /// True when this panel is not directly under the phone: drawn above it, or another app's window slid in between
    /// (Stage Manager re-layers on a stage switch). CGWindowList is front-to-back.
    func needsReorder(under phone: CGWindowID) -> Bool {
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var belowPhone = false
        for w in l {
            let id = w["kCGWindowNumber"] as? Int ?? 0
            if id == windowNumber { return !belowPhone }                       // reached us: fine only if the phone came first
            if id == Int(phone) { belowPhone = true; continue }
            if belowPhone, (w["kCGWindowLayer"] as? Int) == 0, (w["kCGWindowOwnerPID"] as? pid_t) != me { return true }   // someone in between
        }
        return false
    }
}

private final class BandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The only mouse target that actually leaves. Hidden until a ring click (or Esc) reveals it.
final class ExitMark: NSView {
    var onClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func draw(_ dirty: NSRect) {
        let inset = bounds.insetBy(dx: 10, dy: 10)          // 48pt hit, 28pt circle
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let oval = NSBezierPath(ovalIn: inset)
        oval.lineWidth = 2
        oval.stroke()
        let x = NSBezierPath()
        let m: CGFloat = 11
        x.move(to: CGPoint(x: inset.midX - m / 2, y: inset.midY - m / 2))
        x.line(to: CGPoint(x: inset.midX + m / 2, y: inset.midY + m / 2))
        x.move(to: CGPoint(x: inset.midX + m / 2, y: inset.midY - m / 2))
        x.line(to: CGPoint(x: inset.midX - m / 2, y: inset.midY + m / 2))
        x.lineWidth = 2
        x.lineCapStyle = .round
        x.stroke()
    }
}

/// The ring's geometry and furniture, shared by the kiosk's four panels and the window's four bands.
enum Ring {
    /// Band frames (top, bottom, left, right) around `hole` inside `s`, AppKit coords.
    static func rects(around hole: CGRect, in s: CGRect) -> [CGRect] {
        [CGRect(x: s.minX, y: hole.maxY, width: s.width, height: max(0, s.maxY - hole.maxY)),
         CGRect(x: s.minX, y: s.minY, width: s.width, height: max(0, hole.minY - s.minY)),
         CGRect(x: s.minX, y: hole.minY, width: max(0, hole.minX - s.minX), height: hole.height),
         CGRect(x: hole.maxX, y: hole.minY, width: max(0, s.maxX - hole.maxX), height: hole.height)]
    }
    /// The top band's (hidden) × and its hint; both shown and hidden together.
    static func furnish(top: NSView, exit: ExitMark, hint: NSTextField) {
        exit.isHidden = true; hint.isHidden = true
        top.addSubview(exit); top.addSubview(hint)
    }
    /// × flush in the top-right corner (48pt hit, an infinite target), the hint 8pt to its left.
    static func placeExit(_ exit: ExitMark, hint: NSTextField, in top: NSView) {
        exit.frame = NSRect(x: top.bounds.width - 48, y: top.bounds.height - 48, width: 48, height: 48)
        exit.autoresizingMask = [.minXMargin, .minYMargin]
        hint.sizeToFit()
        hint.frame.origin = CGPoint(x: exit.frame.minX - hint.frame.width - 8, y: exit.frame.midY - hint.frame.height / 2)
    }
}

/// Trackpad types WindowServer uses for 3-finger space swipe, pinch, Mission Control. Not two-finger scroll (that's scrollWheel).
private let kioskGestureTypes: [CGEventType] = [
    NSEvent.EventType.rotate, .beginGesture, .endGesture, .gesture, .magnify, .swipe, .smartMagnify,
].compactMap { CGEventType(rawValue: UInt32($0.rawValue)) }

/// Control+arrows switch Spaces / Mission Control; swallow while the ring is up. Other keys reach the mirroring window.
private func kioskSpaceKey(_ e: CGEvent) -> Bool {
    let code = e.getIntegerValueField(.keyboardEventKeycode)
    return e.flags.contains(.maskControl) && (123...126).contains(code)
}

/// Swallows mouse/touch that landed on the ring in screen space but missed our panels (Stage Manager took them off
/// the hit-test path). Also swallows space-switch gestures so the donut cannot follow a 3-finger swipe to an empty hole.
/// Global NSEvent monitors cannot consume events; a HID/session tap can. Own windows still receive the event so the
/// timeline and press-to-exit keep working.
private final class RingTap {
    var shouldPass: ((CGEvent) -> Bool)?
    var onSwallowedClick: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private(set) var running = false

    @discardableResult
    func start() -> Bool {
        stop()
        var kinds: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .tabletPointer, .keyDown, .keyUp,
        ]
        kinds.append(contentsOf: kioskGestureTypes)
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<RingTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let p = me.tap { CGEvent.tapEnable(tap: p, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if kioskGestureTypes.contains(type) || ((type == .keyDown || type == .keyUp) && kioskSpaceKey(event)) {
                return nil
            }
            if me.shouldPass?(event) ?? true { return Unmanaged.passUnretained(event) }
            if type == .leftMouseDown { DispatchQueue.main.async { me.onSwallowedClick?() } }
            return nil
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        // HID sees the swipe before WindowServer turns it into a space switch; session is the fallback.
        var port: CFMachPort?
        for loc: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
            port = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback, userInfo: me)
            if port != nil { break }
        }
        guard let port else {
            print("kiosk: event tap failed — clicks may pass through (Accessibility 권한 확인)")
            return false
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        running = true
        return true
    }

    func stop() {
        if let p = tap { CGEvent.tapEnable(tap: p, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; running = false
    }
}

@MainActor
final class KioskController {
    private let state: AppState
    private let workbench: NSView                          // one Workbench for both rings; moved between their left bands
    private var sub: AnyCancellable?
    private var windows: [NSPanel] = []                    // kiosk: top, bottom, left, right bands; made on the first build
    private var main: NSPanel?                             // the 뽀미 window, made on the first reveal
    private var content: RingContent?
    private var wantMain = false                           // the person wants the window up (until the red button / ×)
    private var lastShown = 0
    private let exitMark: ExitMark
    private let hint = NSTextField(labelWithString: "나가기: Esc 한 번 더 · 또는 ×")   // beside ×, shown with it
    private var kioskBand: PhoneBand?                      // the kiosk's bottom band (the window's is RingContent.band)
    private var pinned = CGRect.zero
    private var tick: Timer?
    private var keyMonitors: [Any] = []
    private var tap: RingTap?
    private var savedPresentation: NSApplication.PresentationOptions = []
    private var lastStage = Date.distantPast
    private var shooting = false                           // a ⌘⇧3/4/5 session is up (sampled by pin)
    private(set) var up = false

    init(state: AppState) {
        self.state = state
        workbench = NSHostingView(rootView: Workbench().environmentObject(state))
        workbench.autoresizingMask = [.width, .height]
        exitMark = ExitMark()
        exitMark.onClick = { [weak self] in self?.leave() }
        hint.font = .systemFont(ofSize: 11); hint.textColor = NSColor(white: 1, alpha: 0.55); hint.isHidden = true
        // objectWillChange fires before the change; look at donut on the next runloop turn, when it is settled.
        sub = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { self.up ? self.pin() : self.dock() } }
        RunLoop.main.add(t, forMode: .common); tick = t
        // ⌃⌘F toggles the kiosk from either ring; Esc works the kiosk's ×. Global sees it with no focus; local eats the chord.
        keyMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
                MainActor.assumeIsolated {
                    if e.keyCode == 53, self.up { self.escPressed() }
                    else if Self.isFullscreenChord(e) { self.state.toggleKiosk() }
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == 53 { var up = false; MainActor.assumeIsolated { up = self.up }; if up { MainActor.assumeIsolated { self.escPressed() } }; return e }
                if Self.isFullscreenChord(e) { DispatchQueue.main.async { MainActor.assumeIsolated { self.state.toggleKiosk() } }; return nil }
                return e
            },
        ].compactMap { $0 }
        sync()
    }

    private func sync() {
        content?.phase = state.phase; windows.forEach { ($0.contentView as? RingView)?.phase = state.phase }   // the rim
        content?.band.sync(); kioskBand?.sync()                                                              // caption, ask buttons
        if state.shown != lastShown { lastShown = state.shown; showMain() }
        // A newly installed binary may need its own Accessibility grant. Keep the workbench usable instead of
        // repeatedly trying to stage a window we cannot control (stage waits on AX on the main thread).
        guard Permissions.accessibility else {
            if up { tear() }
            if state.kioskOn && !wantMain { showMain() }
            return
        }
        // Stage Manager keeps iPhone Mirroring as a ~47x148 strip; axWindow then reports none and donut stays false.
        // Pull it on stage first so toggleKiosk / the green button actually build the ring.
        if state.kioskOn && !up && Date().timeIntervalSince(lastStage) > 2 {
            lastStage = Date()
            if Mirroring.stage() {
                let s = Mirroring.state()
                if s != .none { state.mirroring(s) }
            } else {
                print("kiosk: iPhone 미러링 창이 없음 (실행 중인지, 스테이지에 올랐는지)")
            }
        }
        guard state.donut != up else { return }
        state.donut ? build() : tear()
    }

    /// Put the workbench in a band (the kiosk's or the window's), inset from the rim and the edges.
    private func mount(in band: NSView) {
        if workbench.superview !== band { workbench.removeFromSuperview(); band.addSubview(workbench) }
        workbench.frame = band.bounds.insetBy(dx: 12, dy: 12)
    }

    // MARK: the window

    /// The 뽀미 window. A non-activating panel: key for typing, but the app stays inactive, so Stage Manager keeps the
    /// mirroring window on stage; .canJoinAllApplications keeps the panel there too. Its content is the ring; the title
    /// bar is transparent so only the traffic lights sit on the top band. Green = kiosk (AppDelegate); native fullscreen off.
    private func makeMain() -> NSPanel {
        let c = RingContent(frame: NSRect(origin: .zero, size: RingContent.size(bandWidth: 620, phone: state.phoneSize)))
        c.phoneSize = state.phoneSize
        c.phase = state.phase; c.band.state = state; c.band.sync()        // sync() only runs on a state change
        let p = MainPanel(contentRect: c.frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "뽀미"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .black
        p.isFloatingPanel = false
        // Route raises below the phone at the same level; a lower level would bury the workbench under other apps.
        p.level = .normal
        p.becomesKeyOnlyIfNeeded = true                     // ordinary navigation does not take keyboard focus from the phone
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllApplications, .fullScreenNone]
        p.contentView = c
        p.standardWindowButton(.zoomButton)?.toolTip = "키오스크"
        p.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wantMain = false }
        }
        content = c
        return p
    }
    private func showMain() {
        if main == nil { main = makeMain() }
        wantMain = true
        // fitMain needs self.main. During makeMain it has not been assigned yet, leaving a fresh window unconstrained.
        fitMain()
        if let c = content {
            c.workbench = workbench
            c.needsLayout = true
            c.layoutSubtreeIfNeeded()                         // the bands and docking hole must exist before mounting
            mount(in: c.bands[2])
        }
        main?.orderFront(nil)
    }
    private func closeMain() { wantMain = false; main?.orderOut(nil) }
    private func hideWorkbench() { if main?.isVisible == true { main?.orderOut(nil) } }

    /// Height is the phone's, width is free above the workbench's minimum; keep the window on the visible screen.
    private func fitMain() {
        guard let p = main ?? nil, let c = content else { return }
        Self.fitMain(p, content: c, phoneSize: state.phoneSize)
    }

    /// Window geometry has no dependency on phone permissions or on a live mirroring window.
    static func fitMain(_ p: NSPanel, content c: RingContent, phoneSize: CGSize) {
        c.phoneSize = phoneSize
        let min = RingContent.size(bandWidth: RingContent.bandMin, phone: phoneSize)
        p.contentMinSize = min
        p.contentMaxSize = CGSize(width: 10000, height: min.height)
        let cur = p.contentRect(forFrameRect: p.frame).size
        if cur.height != min.height || cur.width < min.width { p.setContentSize(CGSize(width: Swift.max(cur.width, min.width), height: min.height)) }
        if let v = (p.screen ?? NSScreen.main)?.visibleFrame, p.frame.minY < v.minY || p.frame.maxY > v.maxY {
            p.setFrameOrigin(CGPoint(x: p.frame.minX, y: Swift.max(v.minY, Swift.min(p.frame.minY, v.maxY - p.frame.height))))
        }
        c.layoutSubtreeIfNeeded()
    }

    /// Each tick off the kiosk: keep the mirroring window over the window's hole and just above the window, so the phone
    /// sits in the ring and gets its own clicks. The two move together under Stage Manager: when the phone is parked in
    /// the strip the window hides with it, when it is back the window is back, and ⌘Tab / the Dock icon (which park
    /// the phone) pull it back on stage.
    private func dock() {
        guard wantMain, let w = main, let c = content else { return }
        guard Permissions.accessibility else {
            (w as? MainPanel)?.phoneID = nil                 // a hidden phone must not pull the workbench behind it
            c.hole.hint = "미러링 창을 붙이려면\n설정 › 시작하기에서 손쉬운 사용을 허용해 주세요"
            c.band.sync()
            if !w.isVisible { w.orderFront(nil) }
            return
        }
        guard let phone = Mirroring.liveWindow() else {
            c.hole.hint = Mirroring.app() == nil ? "" : "미러링 창을 연결하고 있습니다"
            if Mirroring.app() == nil { if !w.isVisible { w.orderFront(nil) }; return }       // no mirroring at all: the hole says so
            if NSApp.isActive { if Date().timeIntervalSince(lastStage) > 2 { lastStage = Date(); Mirroring.stage() } }
            else if w.isVisible { w.orderOut(nil) }
            return
        }
        c.hole.hint = ""
        (w as? MainPanel)?.phoneID = phone.id
        if !w.isVisible { w.orderFront(nil) }
        else if let m = w as? MainPanel, m.needsReorder(under: phone.id) { w.order(.below, relativeTo: Int(phone.id)) }   // a raise or an intruder: put it back under the phone
        // WindowServer reports scaled intermediate frames during focus/stage animations. Never dock against those.
        guard let frame = Mirroring.axFrame(), abs(frame.width - phone.rect.width) <= 1,
              abs(frame.height - phone.rect.height) <= 1,
              abs(frame.minX - phone.rect.minX) <= 1, abs(frame.minY - phone.rect.minY) <= 1 else { return }
        if abs(frame.width - state.phoneSize.width) > 1 || abs(frame.height - state.phoneSize.height) > 1 {
            state.phoneSize = frame.size; fitMain(); return
        }
        c.layoutSubtreeIfNeeded()                            // a resize may still have a pending ring layout
        let r = w.convertToScreen(c.hole.convert(c.hole.bounds, to: nil)), main = NSScreen.screens.first?.frame ?? .zero
        let target = CGPoint(x: r.minX, y: main.maxY - r.maxY)                                // AppKit -> CG
        if abs(frame.minX - target.x) > 1 || abs(frame.minY - target.y) > 1 { Mirroring.place(target) }
    }

    // MARK: the kiosk

    /// Put the mirroring window at the reference spot and build the hole around it (once, and again after a size change).
    func build() {
        guard Mirroring.trusted("kiosk") else { return }
        // Stage Manager owns a .regular app's windows and hides them while the app is off stage — the bands would exist
        // (CGWindowList lists them) yet not be drawn, so clicks would land on whatever really is visible behind. An
        // .accessory app is not staged; NSPanel + .canJoinAllApplications keeps the bands on every app's stage, which
        // is how an overlay survives Stage Manager. tear() puts .regular back.
        NSApp.setActivationPolicy(.accessory)
        savedPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = Self.kioskPresentation
        if windows.isEmpty { makeWindows() }
        hideWorkbench()
        let p = Mirroring.homePoint(); Mirroring.place(p)
        pinned = Mirroring.windows().first ?? CGRect(origin: p, size: Mirroring.defaultSize)
        let main = NSScreen.screens.first?.frame ?? .zero
        let s = Mirroring.screen(containing: pinned)?.frame ?? main
        let hole = CGRect(x: pinned.minX, y: main.maxY - pinned.maxY, width: pinned.width, height: pinned.height)   // CG -> AppKit
        for (w, r) in zip(windows, Ring.rects(around: hole, in: s)) { w.setFrame(r, display: true); w.orderFrontRegardless() }
        // band panels start at x = 0: the rim span and the caption are hole coords minus the screen's origin
        let span = (hole.minX - s.minX)...(hole.maxX - s.minX)
        [windows[0], windows[1]].forEach { ($0.contentView as? RingView)?.rimSpan = span }
        if let b = windows[1].contentView { kioskBand?.frame = PhoneBand.frame(underHole: span, in: b.bounds) }
        if !exitMark.isHidden { showExitMark() }
        mount(in: windows[2].contentView!)
        if tap == nil {
            let t = RingTap()
            t.shouldPass = { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, !self.shooting else { return true }   // the Screenshot overlay owns the mouse
                    let p = self.appKitPoint(e)
                    guard self.onRing(p) else { return true }          // hole (and other screens): let the event through
                    let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
                    return self.windows.contains { $0.windowNumber == n }   // ours → deliver; someone else → swallow
                }
            }
            t.onSwallowedClick = { [weak self] in MainActor.assumeIsolated { self?.ringClicked(NSEvent.mouseLocation) } }
            if !t.start() {
                if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { e in
                    MainActor.assumeIsolated { if self.onRing(NSEvent.mouseLocation) { self.ringClicked(NSEvent.mouseLocation) } }
                }) { keyMonitors.append(m) }
            }
            tap = t
        }
        up = true
    }

    /// CGEvent is top-left of the main display; NSWindow frames are bottom-left.
    private func appKitPoint(_ e: CGEvent) -> CGPoint {
        CGPoint(x: e.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - e.location.y)
    }

    /// A screen point (AppKit coords) that lies on one of the bands rather than in the hole. Frames still count when
    /// Stage Manager has taken the panels off the hit-test path (`isVisible` can lie).
    private func onRing(_ p: CGPoint) -> Bool {
        guard up else { return false }
        return windows.contains { $0.frame.contains(p) }
    }

    /// Hide the ring and stop pinning, and hand the screen back: the workbench returns to the window.
    func tear() {
        tap?.stop(); tap = nil
        windows.forEach { $0.orderOut(nil) }
        hideExitMark()
        up = false
        NSApp.presentationOptions = savedPresentation
        NSApp.setActivationPolicy(.regular)                // back to a normal app: Dock icon
        showMain()
    }

    private func makeWindows() {
        windows = (0..<4).map { i in
            let w = BandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false                    // NSPanel default is true: pin() would hide the bands every tick
            w.becomesKeyOnlyIfNeeded = true
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.animationBehavior = .none
            w.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
            let v = RingView(); v.edge = [.minY, .maxY, .maxX, .minX][i]; w.contentView = v   // top, bottom, left, right bands
            v.onPress = { [weak self] in self?.showExitMark() }
            return w
        }
        Ring.furnish(top: windows[0].contentView!, exit: exitMark, hint: hint)
        let band = PhoneBand(); band.state = state; band.sync()
        windows[1].contentView!.addSubview(band); kioskBand = band
    }

    private static let kioskPresentation: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching,
    ]

    /// The system "Enter Full Screen" chord (⌃⌘F). Exits immediately; mouse must hit ×.
    private static func isFullscreenChord(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 3 && mods.contains(.command) && mods.contains(.control)
            && !mods.contains(.shift) && !mods.contains(.option)
    }

    /// Each tick on the kiosk: the window is ours, so it stays where we put it; only a resize (View menu) changes the hole.
    private func pin() {
        guard Permissions.accessibility else { tear(); return }
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        if NSApp.presentationOptions != Self.kioskPresentation { NSApp.presentationOptions = Self.kioskPresentation }
        windows.filter { !$0.isVisible }.forEach { $0.orderFrontRegardless() }
        hideWorkbench()
        // ⌘⇧3/4/5: the Screenshot overlay sits at the menu-bar level (24), under a .screenSaver ring, so its crosshair
        // and toolbar were invisible. While it is up, drop the bands just below it and take focus so our .hideMenuBar
        // (an active-app option) keeps the menu bar out of the top band; back to .screenSaver when it goes.
        let wasShooting = shooting
        shooting = Self.screenshotUp()
        let level: NSWindow.Level = shooting ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1) : .screenSaver
        if windows.first?.level != level { windows.forEach { $0.level = level } }
        if shooting { if !NSApp.isActive { NSApp.activate() } }
        else if wasShooting || !NSApp.isActive, let a = Mirroring.app(), !a.isActive { Mirroring.activate() }
        guard let cur = Mirroring.axFrame(), let visible = Mirroring.liveWindow()?.rect,
              abs(cur.width - visible.width) <= 1, abs(cur.height - visible.height) <= 1,
              abs(cur.minX - visible.minX) <= 1, abs(cur.minY - visible.minY) <= 1 else { return }
        if abs(cur.width - pinned.width) > 1 || abs(cur.height - pinned.height) > 1 { build() }
        else if abs(cur.minX - pinned.minX) > 1 || abs(cur.minY - pinned.minY) > 1 { Mirroring.place(pinned.origin) }
    }

    /// The system Screenshot UI (screencaptureui) has a window on screen: a ⌘⇧3/4/5 session is in progress.
    private static func screenshotUp() -> Bool {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let pids = Set(list.compactMap { $0["kCGWindowOwnerPID"] as? pid_t })
        return pids.contains { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == "com.apple.screencaptureui" }
    }

    /// Mouse on the ring never leaves by itself. If the click landed on × (even when the panel missed hit-test), leave;
    /// otherwise just reveal ×.
    private func ringClicked(_ screen: CGPoint) {
        guard !shooting else { return }
        windows.forEach { $0.orderFrontRegardless() }      // recover panels only when an actual click missed their hit-test path
        if closeMarkContains(screen) { leave() } else { showExitMark() }
    }

    private func escPressed() {
        guard !shooting else { return }                   // Esc cancels the screenshot, not the ring
        if exitMark.isHidden { showExitMark() } else { leave() }
    }

    private func showExitMark() {
        guard let top = windows.first?.contentView else { return }
        Ring.placeExit(exitMark, hint: hint, in: top)
        exitMark.isHidden = false; hint.isHidden = false
        exitMark.needsDisplay = true
    }

    private func hideExitMark() {
        exitMark.isHidden = true; hint.isHidden = true
    }

    private func closeMarkContains(_ screen: CGPoint) -> Bool {
        guard !exitMark.isHidden, let win = exitMark.window else { return false }
        return win.convertToScreen(exitMark.convert(exitMark.bounds, to: nil)).contains(screen)
    }

    private func leave() {
        hideExitMark()
        if state.kioskOn { state.toggleKiosk() }
    }
}
