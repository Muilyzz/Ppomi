import AppKit

/// Four disjoint covers in AppKit screen coordinates. The phone remains a separate, normal-level window.
struct ImmersiveLayout {
    let screen: CGRect
    let phone: CGRect?
    let bands: [CGRect]                         // top, bottom, left, right
    let sidebarIndex: Int
    var sidebar: CGRect { bands[sidebarIndex] }
    var exitFrame: CGRect {
        CGRect(x: screen.maxX - 48, y: screen.maxY - 48, width: 48, height: 48)
    }

    init(screen: CGRect, phone: CGRect?) {
        self.screen = screen
        let intersection = phone?.intersection(screen)
        let hole = intersection.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
        self.phone = hole
        if let hole {
            bands = [
                CGRect(x: screen.minX, y: hole.maxY, width: screen.width, height: screen.maxY - hole.maxY),
                CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: hole.minY - screen.minY),
                CGRect(x: screen.minX, y: hole.minY, width: hole.minX - screen.minX, height: hole.height),
                CGRect(x: hole.maxX, y: hole.minY, width: screen.maxX - hole.maxX, height: hole.height),
            ]
            sidebarIndex = bands[2].width >= bands[3].width ? 2 : 3
        } else {
            let empty = CGRect(origin: screen.origin, size: .zero)
            bands = [empty, empty, screen, empty]
            sidebarIndex = 2
        }
    }
}

/// Keys reveal the exit affordance; a deliberate second Escape exits. Repeated Escape never exits by itself.
struct ImmersiveExitState {
    private(set) var isVisible = false

    mutating func reveal() { isVisible = true }
    mutating func reset() { isVisible = false }
    mutating func keyPressed(isEscape: Bool, isRepeat: Bool) -> Bool {
        let exit = isVisible && isEscape && !isRepeat
        isVisible = true
        return exit
    }
}

private final class ImmersivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ImmersiveBandView: NSView {
    var onPress: (() -> Void)?
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); bounds.fill() }
}

/// Immersive covers own no duplicate workbench or approval state. The controller lends its existing views while active.
/// This class never activates an app, moves the phone, changes application policy, or intercepts global input.
@MainActor
final class ImmersiveKiosk: NSObject {
    private let workbench: NSView
    private let band: PhoneBand
    private let onExit: () -> Void
    private var panels: [ImmersivePanel] = []
    private var exitPanel: ImmersivePanel?
    private var exitState = ImmersiveExitState()
    private var exitRequested = false
    private(set) var screenFrame: CGRect?

    init(workbench: NSView, band: PhoneBand, onExit: @escaping () -> Void) {
        self.workbench = workbench
        self.band = band
        self.onExit = onExit
        super.init()
    }

    func show(on screen: NSScreen, phone: CGRect?) {
        screenFrame = screen.frame
        exitState.reset()
        exitRequested = false
        makePanelsIfNeeded()
        exitPanel?.orderOut(nil)
        update(phone: phone)
    }

    func update(phone: CGRect?) {
        guard let screenFrame else { return }
        let layout = ImmersiveLayout(screen: screenFrame, phone: phone)
        guard let host = panels[layout.sidebarIndex].contentView else { return }
        let remounted = workbench.superview !== host || band.superview !== host
        if remounted { Self.mount(workbench: workbench, band: band, in: host) }
        for (panel, frame) in zip(panels, layout.bands) {
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
                panel.contentView?.needsLayout = true
                WindowDiagnostics.panel("immersive.cover", panel, fields: [
                    "frame": [frame.minX, frame.minY, frame.width, frame.height], "level": panel.level.rawValue])
            }
            if remounted, panel.contentView === host { host.needsLayout = true }
            panel.contentView?.layoutSubtreeIfNeeded()
            if frame.isEmpty {
                if panel.isVisible { panel.orderOut(nil) }
            } else if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
        // Present the actual controls ahead of the otherwise empty cover windows for accessibility.
        if remounted { host.window?.orderFrontRegardless() }
        if let exitPanel, exitPanel.frame != layout.exitFrame { exitPanel.setFrame(layout.exitFrame, display: true) }
        if layout.phone == nil { revealExit() }
        else { updateExitVisibility() }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        exitPanel?.orderOut(nil)
        if panels.contains(where: { $0.contentView === workbench.superview }) { workbench.removeFromSuperview() }
        if panels.contains(where: { $0.contentView === band.superview }) { band.removeFromSuperview() }
        screenFrame = nil
        exitState.reset()
        exitRequested = false
    }

    func revealExit() {
        guard screenFrame != nil else { return }
        exitState.reveal()
        updateExitVisibility()
    }

    /// Called by the owner's local/global monitor. It does not consume, repost, or modify the original event.
    func handleKey(_ event: NSEvent) {
        guard screenFrame != nil, event.type == .keyDown else { return }
        if exitState.keyPressed(isEscape: event.keyCode == 53, isRepeat: event.isARepeat) { requestExit() }
        else { updateExitVisibility() }
    }

    func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return panels.contains { $0 === window } || exitPanel === window
    }

    /// Kept separate from window creation so mounting and layout can be verified without showing any UI.
    static func mount(workbench: NSView, band: PhoneBand, in host: NSView) {
        if workbench.superview !== host { workbench.removeFromSuperview(); host.addSubview(workbench) }
        if band.superview !== host { band.removeFromSuperview(); host.addSubview(band) }
        layoutContent(workbench: workbench, band: band, in: host.bounds)
    }

    static func layoutContent(workbench: NSView, band: PhoneBand, in bounds: CGRect) {
        let width = max(0, bounds.width - 24)
        let footer = band.preferredHeight(for: width)
        band.frame = CGRect(x: bounds.minX + 12, y: bounds.minY + 8, width: width, height: footer)
        workbench.frame = CGRect(x: bounds.minX + 12, y: bounds.minY + footer + 20,
                                 width: width, height: max(0, bounds.height - footer - 32))
        band.needsLayout = true
    }

    private func makePanelsIfNeeded() {
        guard panels.isEmpty else { return }
        panels = (0..<4).map { _ in
            let panel = Self.makePanel()
            let view = ImmersiveBandView()
            view.onPress = { [weak self] in self?.revealExit() }
            view.onLayout = { [weak self, weak view] in
                guard let self, let view, self.workbench.superview === view else { return }
                Self.layoutContent(workbench: self.workbench, band: self.band, in: view.bounds)
            }
            panel.contentView = view
            return panel
        }
        let exit = Self.makePanel()
        exit.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        let button = NSButton(title: "×", target: self, action: #selector(exitPressed))
        button.font = .systemFont(ofSize: 30, weight: .light)
        button.isBordered = false
        button.contentTintColor = .white
        button.setAccessibilityLabel("전체화면 나가기")
        button.toolTip = "전체화면 나가기"
        button.autoresizingMask = [.width, .height]
        let content = ImmersiveBandView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        button.frame = content.bounds
        content.addSubview(button)
        exit.contentView = content
        exitPanel = exit
    }

    private static func makePanel() -> ImmersivePanel {
        let panel = ImmersivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        return panel
    }

    private func updateExitVisibility() {
        guard let exitPanel else { return }
        if exitState.isVisible {
            if !exitPanel.isVisible {
                exitPanel.orderFrontRegardless()
                WindowDiagnostics.panel("immersive.exitShown", exitPanel)
            }
        } else if exitPanel.isVisible {
            exitPanel.orderOut(nil)
        }
    }

    @objc private func exitPressed() { requestExit() }

    private func requestExit() {
        guard !exitRequested else { return }
        exitRequested = true
        onExit()
    }
}
