import AppKit
import XCTest
@testable import Ppomi

final class KioskGeometryTests: XCTestCase {
    /// Configure an unshown native panel: even before AX can measure a phone, all bands must have usable frames.
    @MainActor func testInitialRingGetsMinimumSizeAndNonzeroDockWithoutShowingAWindow() throws {
        _ = NSApplication.shared
        let ring = RingContent(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let panel = NSPanel(contentRect: ring.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = ring
        let workbench = NSView(frame: .zero)
        ring.workbench = workbench
        ring.bands[2].addSubview(workbench)

        KioskController.fitMain(panel, content: ring, phoneSize: CGSize(width: 348, height: 766))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.contentMinSize, CGSize(width: 940, height: 894))
        XCTAssertEqual(panel.contentMaxSize.height, 894)
        XCTAssertEqual(ring.hole.bounds.size, CGSize(width: 348, height: 766))
        XCTAssertGreaterThanOrEqual(workbench.frame.width, 536)
        XCTAssertEqual(workbench.frame.height, 742)

        KioskController.fitMain(panel, content: ring, phoneSize: CGSize(width: 300, height: 650))
        XCTAssertEqual(panel.contentMinSize, CGSize(width: 892, height: 778))
        XCTAssertEqual(ring.hole.bounds.size, CGSize(width: 300, height: 650))
        XCTAssertEqual(workbench.frame.height, 626)
    }
}
