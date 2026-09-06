import XCTest
@testable import Ppomi

final class MirrorPresenceTests: XCTestCase {
    func testOneMissingFrameRetainsAssociationButSustainedAbsenceExpires() {
        var presence = MirrorPresence()
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: true, hasAssociation: true, now: 10), .live)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 10.25), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 10.5), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 10.75), .absent)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 11), .absent)
    }

    func testLiveWindowResetsGraceForLaterTransition() {
        var presence = MirrorPresence()
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 30), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: true, hasAssociation: true, now: 30.25), .live)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 30.5), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 30.75), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 31), .absent)
    }

    func testAppExitClearsImmediatelyEvenDuringGrace() {
        var presence = MirrorPresence()
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 50), .transient)
        XCTAssertEqual(presence.observe(appRunning: false, hasLiveWindow: false, hasAssociation: true, now: 50.01), .absent)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 55), .transient)
    }

    func testAbsentWindowWithoutExistingAssociationHasNoGrace() {
        var presence = MirrorPresence()
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: false, now: 70), .absent)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: true, now: 71), .transient)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: false, hasAssociation: false, now: 71.1), .absent)
        XCTAssertEqual(presence.observe(appRunning: true, hasLiveWindow: true, hasAssociation: false, now: 72), .live)
    }
}
