import XCTest
@testable import Ppomi

final class VoiceTests: XCTestCase {
    func testWakeWordCommand() {
        XCTAssertNil(WakeWord.command(in: "오늘 지출 얼마야"))
        XCTAssertNil(WakeWord.command(in: ""))
        XCTAssertEqual(WakeWord.command(in: "뽀미야"), "")
        XCTAssertEqual(WakeWord.command(in: "뽀미야?"), "")
        XCTAssertEqual(WakeWord.command(in: "뽀미야, 오늘 지출 얼마야"), "오늘 지출 얼마야")
        XCTAssertEqual(WakeWord.command(in: "어 뽀미 야 잔액"), "잔액")
        XCTAssertEqual(WakeWord.command(in: "보미야 타니베이 예약해줘"), "타니베이 예약해줘")
    }

    /// The state machine without a microphone: one turn per utterance, 1.2 s after its final; a volatile guess is not
    /// enough; "뽀미야" opens the conversation, every utterance after it is a turn, a stop word closes it.
    @MainActor func testCommandOncePerUtterance() async throws {
        let v = Voice()
        var got: [String] = []
        v.onCommand = { got.append($0) }
        v.set(.waiting)
        v.handle("뽀미야 오늘", final: false)
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, [])
        v.handle("뽀미야 오늘 지출 얼마야", final: true)
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, ["오늘 지출 얼마야"])
        v.handle("뽀미야", final: true)
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, ["오늘 지출 얼마야"])
        v.handle("잔액", final: true)
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, ["오늘 지출 얼마야", "잔액"])
        v.handle("그냥 혼잣말", final: true)                    // the conversation is open: no wake word needed
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, ["오늘 지출 얼마야", "잔액", "그냥 혼잣말"])
        v.handle("그만", final: true)                          // a stop word closes it
        try await Task.sleep(for: .seconds(1.4))
        v.handle("혼잣말", final: true)                        // closed: ignored until the next 뽀미야
        try await Task.sleep(for: .seconds(1.4))
        XCTAssertEqual(got, ["오늘 지출 얼마야", "잔액", "그냥 혼잣말"])
        v.stop()
    }

    func testLooseWakeAtStartOfUtterance() {
        XCTAssertEqual(WakeWord.command(in: "이야 오늘 지출 얼마야?"), "오늘 지출 얼마야")   // trailing ? trimmed like the rest   // what the model hears for "뽀미야"
        XCTAssertEqual(WakeWord.command(in: " 폼이야"), "")
        XCTAssertEqual(WakeWord.command(in: "미야 오늘 날짜"), "오늘 날짜")
        XCTAssertNil(WakeWord.command(in: "이야기 좀 하자"))                                // a real word, not the name
        XCTAssertNil(WakeWord.command(in: "오늘 지출 얼마야"))
    }
}
