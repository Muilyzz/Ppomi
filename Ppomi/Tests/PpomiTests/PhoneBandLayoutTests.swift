import AppKit
import XCTest
@testable import Ppomi

final class PhoneBandLayoutTests: XCTestCase {
    /// A phone moved into the middle can leave a narrow sidebar. All choices must remain actual, visible buttons.
    @MainActor func testNarrowApprovalColumnFitsAndLayoutDoesNotAnswer() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ppomi-band-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        let db = try DB(path: path, writable: true)
        let options = ["결제 승인 · 예약 내용을 확인한 뒤 진행", "다른 결제 수단을 선택하고 다시 확인", "예약 날짜와 숙소 정보를 다시 확인", "취소하고 이전 화면으로 돌아가기"]
        let pending: [String: Any] = ["id": "layout-only", "html": "진행할 동작을 직접 선택해 주세요", "options": options]
        try db.setState("ask:pending", String(decoding: JSONSerialization.data(withJSONObject: pending), as: UTF8.self))
        let state = AppState()
        state.watchAsks(dbPath: path)
        state.pollAsk()
        let band = PhoneBand()
        band.state = state
        band.sync()
        let stack = try XCTUnwrap(band.subviews.compactMap { $0 as? NSStackView }.first)
        let choices = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(choices.map(\.title), options)

        let width: CGFloat = 180
        let height = band.preferredHeight(for: width)
        XCTAssertGreaterThan(height, 116)
        band.frame = CGRect(x: 0, y: 0, width: width, height: height)
        band.layoutSubtreeIfNeeded()
        XCTAssertEqual(stack.orientation, .vertical)
        for choice in choices {
            let frame = band.convert(choice.bounds, from: choice)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertGreaterThanOrEqual(frame.minY, -1)
            XCTAssertLessThanOrEqual(frame.maxX, band.bounds.maxX + 1)
            XCTAssertLessThanOrEqual(frame.maxY, band.bounds.maxY + 1)
        }
        XCTAssertNil(try db.state("ask:answer:layout-only"))
        XCTAssertEqual(state.ask?.id, "layout-only")

        // Repeated measurement and a wider layout retain the same choices and do not synthesize a human action.
        let wide: CGFloat = 1600
        band.frame.size = CGSize(width: wide, height: band.preferredHeight(for: wide))
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        XCTAssertEqual(stack.orientation, .horizontal)
        XCTAssertNil(try db.state("ask:answer:layout-only"))
        XCTAssertEqual(choices.map(\.title), options)

        choices[3].performClick(nil)
        XCTAssertEqual(try db.state("ask:answer:layout-only"), options[3])
        XCTAssertNil(state.ask)
    }
}
