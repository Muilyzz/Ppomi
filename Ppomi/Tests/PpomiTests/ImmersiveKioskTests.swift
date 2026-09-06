import AppKit
import XCTest
@testable import Ppomi

final class ImmersiveKioskTests: XCTestCase {
    func testBandsCoverExactlyTheScreenOutsideThePhone() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let phone = CGRect(x: 1020, y: 90, width: 348, height: 720)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone)
        assertCoverage(layout)
        XCTAssertGreaterThan(layout.sidebar.width, 600)
        XCTAssertEqual(layout.sidebar, layout.bands[layout.sidebarIndex])
    }

    func testClampedTallPhoneWithNegativeScreenOriginKeepsAllMasksOnScreen() {
        let screen = CGRect(x: -1440, y: -180, width: 1440, height: 900)
        let phone = CGRect(x: -440, y: -250, width: 348, height: 1100)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
        XCTAssertEqual(layout.phone?.height, screen.height)
        XCTAssertGreaterThan(layout.sidebar.width, 900)
    }

    func testPartlyOffscreenPhoneOnOffsetDisplayLeavesNoMaskGaps() {
        let screen = CGRect(x: 240, y: 120, width: 1280, height: 720)
        let phone = CGRect(x: 1450, y: 180, width: 348, height: 650)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertEqual(layout.phone, phone.intersection(screen))
        assertCoverage(layout)
    }

    func testAbsentOrEntirelyOffscreenPhoneProducesFullCoverAndUsableSidebar() {
        let screen = CGRect(x: 300, y: -700, width: 1200, height: 700)
        for phone in [nil, CGRect(x: -900, y: 600, width: 348, height: 720)] as [CGRect?] {
            let layout = ImmersiveLayout(screen: screen, phone: phone)
            XCTAssertNil(layout.phone)
            assertCoverage(layout)
            XCTAssertEqual(layout.sidebar, screen)
        }
    }

    func testExitTargetRemainsFullSizeWhenGapAbovePhoneIsShort() {
        let screen = CGRect(x: 180, y: 220, width: 1280, height: 720)
        let phone = CGRect(x: 1060, y: 230, width: 348, height: 700)
        let layout = ImmersiveLayout(screen: screen, phone: phone)
        XCTAssertLessThan(screen.maxY - phone.maxY, 48)
        XCTAssertEqual(layout.exitFrame.size, CGSize(width: 48, height: 48))
        XCTAssertTrue(screen.contains(layout.exitFrame))
        assertCoverage(layout)
    }

    func testKeyboardRevealsExitAndEscapeRequiresTwoDistinctPresses() {
        var state = ImmersiveExitState()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.keyPressed(isEscape: false, isRepeat: false))
        XCTAssertTrue(state.isVisible)

        state.reset()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.keyPressed(isEscape: true, isRepeat: false))
        XCTAssertTrue(state.isVisible)
        for _ in 0..<5 { XCTAssertFalse(state.keyPressed(isEscape: true, isRepeat: true)) }
        XCTAssertTrue(state.keyPressed(isEscape: true, isRepeat: false))

        state.reset()
        state.reveal()
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.keyPressed(isEscape: true, isRepeat: false))
    }

    @MainActor func testMountingRetainsTheSameWorkbenchAndApprovalViewsWithoutShowingWindows() {
        _ = NSApplication.shared
        let workbench = NSView()
        let band = PhoneBand()
        let originalHost = NSView(frame: CGRect(x: 0, y: 0, width: 620, height: 900))
        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))

        for host in [originalHost, immersiveHost, originalHost] {
            ImmersiveKiosk.mount(workbench: workbench, band: band, in: host)
            ImmersiveKiosk.layoutContent(workbench: workbench, band: band, in: host.bounds)
            XCTAssertTrue(workbench.superview === host)
            XCTAssertTrue(band.superview === host)
            XCTAssertEqual(host.subviews.filter { $0 === workbench }.count, 1)
            XCTAssertEqual(host.subviews.filter { $0 === band }.count, 1)
            XCTAssertTrue(host.bounds.contains(workbench.frame))
            XCTAssertTrue(host.bounds.contains(band.frame))
            XCTAssertFalse(workbench.frame.intersects(band.frame))
            XCTAssertGreaterThan(workbench.frame.height, 0)
            XCTAssertGreaterThan(band.frame.height, 0)
            XCTAssertNil(workbench.window)
            XCTAssertNil(band.window)
        }
        XCTAssertFalse(immersiveHost.subviews.contains { $0 === workbench || $0 === band })
    }

    @MainActor func testSuspendedNormalLayoutCannotResizeViewsLentToImmersiveHost() {
        _ = NSApplication.shared
        let originalFrame = CGRect(x: 0, y: 0, width: 940, height: 894)
        let content = WorkbenchContent(frame: originalFrame)
        let workbench = NSView()
        content.workbench = workbench
        content.workbenchArea.addSubview(workbench)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        let normalWorkbenchFrame = workbench.frame
        let normalBandFrame = content.band.frame
        XCTAssertGreaterThan(normalWorkbenchFrame.height, 0)

        let immersiveHost = NSView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))
        content.layoutSuspended = true
        ImmersiveKiosk.mount(workbench: workbench, band: content.band, in: immersiveHost)
        let immersiveWorkbenchFrame = workbench.frame
        let immersiveBandFrame = content.band.frame
        XCTAssertNotEqual(immersiveWorkbenchFrame, normalWorkbenchFrame)

        // A hidden normal host can still receive layout while its existing views belong to another window.
        content.frame.size = CGSize(width: 1240, height: 1080)
        content.layout()
        XCTAssertTrue(workbench.superview === immersiveHost)
        XCTAssertTrue(content.band.superview === immersiveHost)
        XCTAssertEqual(workbench.frame, immersiveWorkbenchFrame)
        XCTAssertEqual(content.band.frame, immersiveBandFrame)

        content.frame = originalFrame
        content.workbenchArea.addSubview(workbench)
        content.addSubview(content.band)
        content.layoutSuspended = false
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(workbench.superview === content.workbenchArea)
        XCTAssertTrue(content.band.superview === content)
        XCTAssertEqual(workbench.frame, normalWorkbenchFrame)
        XCTAssertEqual(content.band.frame, normalBandFrame)
        XCTAssertNil(workbench.window)
        XCTAssertNil(content.band.window)
    }

    private func assertCoverage(_ layout: ImmersiveLayout, file: StaticString = #filePath, line: UInt = #line) {
        let masks = layout.bands.filter { $0.width > 0 && $0.height > 0 }
        let hole = layout.phone
        for (index, mask) in masks.enumerated() {
            XCTAssertTrue(layout.screen.contains(mask), "A mask extends outside the display", file: file, line: line)
            if let hole {
                XCTAssertEqual(area(mask.intersection(hole)), 0, accuracy: 0.001,
                               "A mask obscures the phone", file: file, line: line)
            }
            for other in masks.dropFirst(index + 1) {
                XCTAssertEqual(area(mask.intersection(other)), 0, accuracy: 0.001,
                               "Masks overlap", file: file, line: line)
            }
        }
        XCTAssertEqual(masks.reduce(0) { $0 + area($1) } + (hole.map(area) ?? 0), area(layout.screen),
                       accuracy: 0.001, "The screen has an uncovered gap", file: file, line: line)
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
