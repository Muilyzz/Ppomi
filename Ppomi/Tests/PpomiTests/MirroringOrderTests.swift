import XCTest
@testable import Ppomi

final class MirroringOrderTests: XCTestCase {
    private let phone = MirroringOrder.Window(id: 31, owner: 100, layer: 0)
    private let ppomi = MirroringOrder.Window(id: 32, owner: 200, layer: 0)
    private let foreign = MirroringOrder.Window(id: 33, owner: 300, layer: 0)

    func testLiveButBuriedPhoneIsNotRevealed() {
        XCTAssertFalse(revealed([foreign, phone, ppomi]))
        XCTAssertFalse(revealed([ppomi, foreign, phone]))
    }

    func testPhoneAheadOfOtherApplicationsIsRevealed() {
        XCTAssertTrue(revealed([phone, ppomi, foreign]))
        XCTAssertTrue(revealed([ppomi, phone, foreign]))
    }

    func testSystemLevelsAndSameApplicationWindowsDoNotBlockReveal() {
        let menu = MirroringOrder.Window(id: 40, owner: 300, layer: 24)
        let mirrorAuxiliary = MirroringOrder.Window(id: 41, owner: 100, layer: 0)
        XCTAssertTrue(revealed([menu, mirrorAuxiliary, ppomi, phone, foreign]))
    }

    func testMissingOrWrongOwnerPhoneCannotReportSuccess() {
        XCTAssertFalse(revealed([]))
        XCTAssertFalse(revealed([ppomi]))
        XCTAssertFalse(revealed([.init(id: 31, owner: 200, layer: 0)]))
        XCTAssertFalse(revealed([.init(id: 31, owner: 100, layer: 3)]))
    }

    private func revealed(_ windows: [MirroringOrder.Window]) -> Bool {
        MirroringOrder.isInFront(phoneID: 31, phonePID: 100, ppomiPID: 200, windows: windows)
    }
}
