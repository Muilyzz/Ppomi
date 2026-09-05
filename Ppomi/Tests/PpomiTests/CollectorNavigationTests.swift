import XCTest
@testable import Ppomi

final class CollectorNavigationTests: XCTestCase {
    private func word(_ text: String, x: Double = 0.05, y: Double = 0.12) -> OCR.Word {
        .init(x: x, y: y, w: 0.2, h: 0.02, text: text)
    }

    func testBroadImportedSelectorCannotTapPaymentOrTransfer() throws {
        for text in ["결제하기", "송금", "계좌이체", "주문 완료", "충전"] {
            let match = try XCTUnwrap(Phone.find([word(text), word("거래내역")], "."))
            XCTAssertThrowsError(try Collector.checkedReadTarget(match)) { error in
                XCTAssertTrue(error is Collector.Skip)
            }
        }
        for text in ["거래내역", "내 계좌 전체보기", "KB국민ONE통장", "더보기"] {
            XCTAssertEqual(try Collector.checkedReadTarget(word(text)).text, text)
        }
    }

    func testBackNavigationNeverFallsBackToHeaderText() throws {
        XCTAssertNil(Collector.backTarget(in: [word("결제하기"), word("거래내역")]))
        XCTAssertNil(Collector.backTarget(in: [word("←", x: 0.8)]))
        XCTAssertNil(Collector.backTarget(in: [word("←", y: 0.7)]))
        for glyph in ["^", "<", "〈", "←", "‹"] {
            let target = try XCTUnwrap(Collector.backTarget(in: [word("결제하기"), word(glyph, x: 0.1)]))
            XCTAssertEqual(target.text, glyph)
        }
    }
}
