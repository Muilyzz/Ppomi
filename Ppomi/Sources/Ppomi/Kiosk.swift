// One normal-level workbench window, immediately behind iPhone Mirroring in both size modes.
// Expanded mode resizes this same panel on the current desktop. It does not create a Space, seize focus,
// suppress gestures, or cover system UI. Only deliberate workbench geometry changes reposition the phone.
import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// Navigation leaves the mirroring app active; every explicit raise stays directly behind its window.
final class MainPanel: NSPanel {
    var phoneID: CGWindowID?
    private var kioskAction: (() -> Void)?

    /// Bind the button's semantic action so mouse clicks, accessibility presses, and performZoom agree.
    /// The controller supplies its state directly; no application-delegate launch ordering is required.
    func bindKioskButton(_ action: @escaping () -> Void) {
        kioskAction = action
        guard let button = standardWindowButton(.zoomButton) else { return }
        button.target = self
        button.action = #selector(performZoom(_:))
        button.toolTip = "키오스크"
        button.setAccessibilityLabel("키오스크")
    }
    override func performZoom(_ sender: Any?) {
        if let kioskAction { kioskAction() }
        else { super.performZoom(sender) }
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .above, let p = phoneID { super.order(.below, relativeTo: Int(p)) }
        else { super.order(place, relativeTo: otherWin) }
    }
    override func orderFront(_ sender: Any?) {
        if let p = phoneID { order(.below, relativeTo: Int(p)) } else { super.orderFront(sender) }
    }
    override func orderFrontRegardless() {
        if let p = phoneID { order(.below, relativeTo: Int(p)) } else { super.orderFrontRegardless() }
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


/// Stable geometry snapshots use WindowServer coordinates (origin at the main screen's top left).
struct DockSnapshot {
    let phoneID: CGWindowID
    let panel: CGRect
    let phone: CGRect
}

enum DockChange: Equatable {
    case none, alignPhone, followPhone

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
        abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// A tab click or focus change has no geometry effect. A phone-only move must never be undone.
    static func between(_ previous: DockSnapshot?, and current: DockSnapshot, explicitLayout: Bool) -> DockChange {
        if explicitLayout { return .alignPhone }
        guard let previous, previous.phoneID == current.phoneID else { return .followPhone }
        if !near(previous.panel, current.panel) { return .alignPhone }
        if !near(previous.phone, current.phone) { return .followPhone }
        return .none
    }
}

@MainActor
final class KioskController {
    private let state: AppState
    private let workbench: NSView
    private var sub: AnyCancellable?
    private var main: MainPanel?
    private var content: WorkbenchContent?
    private var wantMain = false
    private var lastShown = 0
    private var tick: Timer?
    private var keyMonitors: [Any] = []
    private var savedFrame: CGRect?
    private var lastDock: DockSnapshot?
    private var placementRequested = false
    private(set) var up = false

    init(state: AppState) {
        self.state = state
        workbench = NSHostingView(rootView: Workbench().environmentObject(state))
        workbench.autoresizingMask = [.width, .height]
        sub = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dock() }
        }
        RunLoop.main.add(t, forMode: .common); tick = t
        keyMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, self.main?.isVisible == true,
                          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Mirroring.bundleID,
                          Self.isFullscreenChord(e) else { return }
                    self.state.toggleKiosk()
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let main = self.main, e.window === main,
                      Self.isFullscreenChord(e) else { return e }
                DispatchQueue.main.async { self.state.toggleKiosk() }
                return nil
            },
        ].compactMap { $0 }
        sync()
    }

    deinit {
        tick?.invalidate()
        keyMonitors.forEach(NSEvent.removeMonitor)
    }

    private func sync() {
        content?.phase = state.phase
        content?.band.sync()
        if state.shown != lastShown { lastShown = state.shown; showMain() }
        if state.kioskOn != up { setExpanded(state.kioskOn) }
    }

    private func makeMain() -> MainPanel {
        let c = WorkbenchContent(frame: CGRect(origin: .zero,
                                size: WorkbenchContent.size(bandWidth: 620, phone: state.phoneSize)))
        c.phoneSize = state.phoneSize
        c.phase = state.phase; c.band.state = state; c.band.sync()
        c.workbench = workbench
        c.workbenchArea.addSubview(workbench)
        c.onExitExpanded = { [weak self] in self?.state.toggleKiosk() }
        let p = MainPanel(contentRect: c.frame,
                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.title = "뽀미"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .black
        p.isFloatingPanel = false
        p.level = .normal
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllApplications, .fullScreenNone]
        p.contentView = c
        p.bindKioskButton { [weak self] in self?.state.toggleKiosk() }
        p.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wantMain = false }
        }
        content = c
        return p
    }

    private func showMain(stage: Bool = true) {
        let first = main == nil
        if first { main = makeMain() }
        wantMain = true
        guard let p = main, let c = content else { return }
        if first { Self.fitMain(p, content: c, phoneSize: state.phoneSize); placementRequested = true }
        // Only an explicit request to show the workbench may retrieve a parked mirroring window.
        if stage, Permissions.accessibility, Mirroring.app() != nil, Mirroring.liveWindow() == nil {
            Mirroring.stage()
        }
        p.phoneID = Mirroring.liveWindow()?.id
        c.layoutSubtreeIfNeeded()
        p.orderFront(nil)
    }

    /// Change only the existing panel's geometry; its content and window number remain the same.
    private func setExpanded(_ expanded: Bool) {
        if main == nil { showMain(stage: false) }
        guard let p = main, let c = content else { return }
        if expanded {
            savedFrame = p.frame
            let screen = p.screen ?? NSScreen.main
            Self.fitExpanded(p, content: c, in: screen?.visibleFrame ?? p.frame)
        } else {
            c.expanded = false
            c.followedPhone = nil
            p.contentMinSize = .zero
            p.contentMaxSize = CGSize(width: 10000, height: 10000)
            if let savedFrame { p.setFrame(savedFrame, display: true) }
            Self.fitMain(p, content: c, phoneSize: state.phoneSize)
            savedFrame = nil
        }
        up = expanded
        placementRequested = true
        p.standardWindowButton(.zoomButton)?.setAccessibilityLabel(expanded ? "키오스크 끄기" : "키오스크")
        showMain()
    }

    static func fitExpanded(_ p: NSPanel, content c: WorkbenchContent, in frame: CGRect) {
        c.expanded = true
        c.followedPhone = nil
        p.contentMinSize = .zero
        p.contentMaxSize = CGSize(width: 10000, height: 10000)
        p.setFrame(frame, display: true)
        c.layoutSubtreeIfNeeded()
    }

    static func fitMain(_ p: NSPanel, content c: WorkbenchContent, phoneSize: CGSize) {
        c.phoneSize = phoneSize
        let min = WorkbenchContent.size(bandWidth: WorkbenchContent.bandMin, phone: phoneSize)
        p.contentMinSize = min
        p.contentMaxSize = CGSize(width: 10000, height: min.height)
        let cur = p.contentRect(forFrameRect: p.frame).size
        if cur.height != min.height || cur.width < min.width {
            p.setContentSize(CGSize(width: Swift.max(cur.width, min.width), height: min.height))
        }
        if let v = (p.screen ?? NSScreen.main)?.visibleFrame, p.frame.minY < v.minY || p.frame.maxY > v.maxY {
            p.setFrameOrigin(CGPoint(x: p.frame.minX, y: Swift.max(v.minY, Swift.min(p.frame.minY, v.maxY - p.frame.height))))
        }
        c.layoutSubtreeIfNeeded()
    }

    private func cgRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
               width: rect.width, height: rect.height)
    }

    private func phoneTarget(_ p: NSPanel, _ c: WorkbenchContent) -> CGRect {
        cgRect(p.convertToScreen(c.phoneSlot.convert(c.phoneSlot.bounds, to: nil)))
    }

    private func followPhone(_ frame: CGRect, panel p: MainPanel, content c: WorkbenchContent) {
        if up {
            // In expanded mode the backing stays screen-sized; its layout follows the user's phone position.
            let local = c.convert(p.convertFromScreen(cgRect(frame)), from: nil)
            c.followedPhone = local
            c.layoutSubtreeIfNeeded()
        } else {
            let target = phoneTarget(p, c)
            p.setFrameOrigin(CGPoint(x: p.frame.minX + frame.minX - target.minX,
                                    y: p.frame.minY - (frame.minY - target.minY)))
        }
    }

    /// Maintain relative order without raising/activating the phone. Ignore transient Stage Manager animation frames.
    private func dock() {
        guard wantMain, let p = main, let c = content else { return }
        guard Permissions.accessibility else {
            p.phoneID = nil; lastDock = nil
            c.phoneSlot.hint = "미러링 창을 붙이려면\n설정 › 시작하기에서 손쉬운 사용을 허용해 주세요"
            if !p.isVisible { p.orderFront(nil) }
            return
        }
        guard let phone = Mirroring.liveWindow() else {
            p.phoneID = nil; lastDock = nil
            c.phoneSlot.hint = "iPhone 미러링을 연결해 주세요"
            // Follow the phone off stage without pulling the user back from another app or Space.
            if Mirroring.app() != nil, !NSApp.isActive, !p.isKeyWindow { p.orderOut(nil) }
            else if !p.isVisible { p.orderFront(nil) }
            return
        }
        guard let frame = Mirroring.axFrame(), DockChange.near(frame, phone.rect) else { return }
        p.phoneID = phone.id
        if !p.isVisible { p.orderFront(nil) }
        else if p.needsReorder(under: phone.id) { p.order(.below, relativeTo: Int(phone.id)) }
        c.phoneSlot.hint = ""
        let current = DockSnapshot(phoneID: phone.id, panel: cgRect(p.frame), phone: frame)
        let change = DockChange.between(lastDock, and: current, explicitLayout: placementRequested)
        let resized = abs(frame.width - state.phoneSize.width) > 1 || abs(frame.height - state.phoneSize.height) > 1
        if resized {
            state.phoneSize = frame.size
            c.phoneSize = frame.size
            if !up { Self.fitMain(p, content: c, phoneSize: frame.size) }
        }
        if change == .alignPhone {
            c.followedPhone = nil
            c.layoutSubtreeIfNeeded()
            let target = phoneTarget(p, c)
            if abs(frame.minX - target.minX) > 1 || abs(frame.minY - target.minY) > 1 {
                Mirroring.place(target.origin)
            }
        } else if change == .followPhone || resized {
            c.layoutSubtreeIfNeeded()
            followPhone(frame, panel: p, content: c)
        }
        placementRequested = false
        // Record the actual result (including any OS position constraint), never repeatedly force an unattainable point.
        let actual = change == .alignPhone ? (Mirroring.axFrame() ?? frame) : frame
        if change == .alignPhone, !DockChange.near(actual, phoneTarget(p, c)) { followPhone(actual, panel: p, content: c) }
        lastDock = DockSnapshot(phoneID: phone.id, panel: cgRect(p.frame), phone: actual)
    }

    private static func isFullscreenChord(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 3 && mods.contains(.command) && mods.contains(.control)
            && !mods.contains(.shift) && !mods.contains(.option)
    }
}
