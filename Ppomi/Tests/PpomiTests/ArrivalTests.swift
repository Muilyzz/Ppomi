// Arrival.shouldGreet at its edges: 30 min since the last greeting, 60 s of idle, the lock, the mute, the quiet hours.
import XCTest
@testable import Ppomi

final class ArrivalTests: XCTestCase {
    func at(_ h: Int, _ m: Int = 0) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
    func greet(now: Date? = nil, last: Date? = nil, idle: Double = 0, locked: Bool = false, muted: Bool = false) -> Bool {
        Arrival.shouldGreet(now: now ?? at(12), lastGreet: last, idleSeconds: idle, screenLocked: locked, muted: muted)
    }

    func testEdges() {
        XCTAssertTrue(greet())
        XCTAssertTrue(greet(last: at(12).addingTimeInterval(-1800)))
        XCTAssertFalse(greet(last: at(12).addingTimeInterval(-1799)))
        XCTAssertTrue(greet(idle: 59.9)); XCTAssertFalse(greet(idle: 60))
        XCTAssertFalse(greet(locked: true)); XCTAssertFalse(greet(muted: true))
        XCTAssertFalse(greet(now: at(23))); XCTAssertTrue(greet(now: at(22, 59)))
        XCTAssertFalse(greet(now: at(6, 59))); XCTAssertTrue(greet(now: at(7)))
        XCTAssertFalse(greet(now: at(3)))
    }

    /// `Ppomi --voice` leaves "voice:open"; the console's poll eats it and bumps voiceOpen. "greet:on" survives restarts.
    @MainActor func testVoiceOpenTriggerAndGreetSwitch() throws {
        let path = NSTemporaryDirectory() + "ppomi-voice-\(UUID().uuidString)/ledger.db"
        let other = try DB(path: path, writable: true)
        try other.setState("greet:on", "0"); try other.setState("voice:open", "2026-09-05 10:00")
        let s = AppState(); s.watchAsks(dbPath: path)
        XCTAssertFalse(s.greetOnArrival)
        s.toggleGreet(); XCTAssertTrue(s.greetOnArrival); XCTAssertEqual(try other.state("greet:on"), "1")
        s.pollAsk(); s.pollAsk()
        XCTAssertEqual(s.voiceOpen, 1); XCTAssertNil(try other.state("voice:open"))
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
