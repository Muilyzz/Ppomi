import AppKit
import XCTest
@testable import Ppomi

final class AppDelegateTests: XCTestCase {
    /// A visible Settings window must not stop a Dock click from reopening the workbench.
    @MainActor func testReopenRevealsWorkbenchRegardlessOfVisibleWindows() {
        for visible in [false, true] {
            let state = AppState()
            state.show(.playbooks)
            let delegate = AppDelegate()
            delegate.state = state

            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible))
            XCTAssertEqual(state.shown, 1)
            XCTAssertEqual(state.tab, .playbooks)
        }
    }

    /// Revealing the window in kiosk would remount the one shared workbench away from the kiosk.
    @MainActor func testReopenPreservesKioskAndDoesNotRevealWindow() {
        for visible in [false, true] {
            let state = AppState()
            state.show(.playbooks)
            state.toggleKiosk()
            let delegate = AppDelegate()
            delegate.state = state

            XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: visible))
            XCTAssertEqual(state.shown, 0)
            XCTAssertTrue(state.kioskOn)
            XCTAssertEqual(state.phase, .humanUse(onScreen: true))
            XCTAssertEqual(state.tab, .playbooks)
        }
    }

    @MainActor func testReopenUsesPendingStateBeforeLaunchDelegateReceivesIt() {
        let previous = AppDelegate.pendingState
        defer { AppDelegate.pendingState = previous }
        let state = AppState()
        AppDelegate.pendingState = state

        XCTAssertFalse(AppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(state.shown, 1)
    }
}
