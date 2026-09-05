// telemetry.jsonl next to a temp ledger: one line per record, only whitelisted fields survive, and a gate refusal is traced.
import XCTest
@testable import Ppomi

final class TelemetryTests: XCTestCase {
    func testRecordKeepsNamesAndNumbersOnly() throws {
        let dir = NSTemporaryDirectory() + "ppomi-tel-\(UUID().uuidString)"
        let db = try DB(path: dir + "/ledger.db", writable: true)
        Telemetry.record("tool", ["name": "phone_tap", "ok": true, "ms": 12, "amount": 406600, "text": "결제하기", "merchant": "여기어때",
                                  "app": String(repeating: "x", count: 41), "reason": "a\nb"], db: db)
        Telemetry.record("gate", ["tool": "phone_tap", "reason": "consent"], db: db)
        let lines = try String(contentsOfFile: dir + "/telemetry.jsonl", encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["event"] as? String, "tool"); XCTAssertNotNil(first["ts"])
        let f = first["fields"] as! [String: Any]
        XCTAssertEqual(Set(f.keys), ["name", "ok", "ms"])                    // amount, text, merchant, long/multiline strings: dropped
        XCTAssertEqual(f["name"] as? String, "phone_tap"); XCTAssertEqual(f["ms"] as? Int, 12)
        XCTAssertFalse(lines[0].contains("406600") || lines[0].contains("결제하기") || lines[0].contains("여기어때"))
        XCTAssertTrue(lines[1].contains("\"reason\":\"consent\""))
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testGateRefusalIsTraced() throws {
        let dir = NSTemporaryDirectory() + "ppomi-tel-\(UUID().uuidString)"
        let t = try Tools(db: try DB(path: dir + "/ledger.db", writable: true))
        t.currentText = "오늘 얼마 썼어?"                                        // no consent: refused before the phone is touched
        XCTAssertTrue(t.execute("phone_tap", ["text": "결제하기"]).hasPrefix("실행 안 함"))
        let log = try String(contentsOfFile: dir + "/telemetry.jsonl", encoding: .utf8)
        XCTAssertTrue(log.contains("\"event\":\"gate\"") && log.contains("\"reason\":\"consent\"") && log.contains("\"tool\":\"phone_tap\""), log)
        XCTAssertTrue(log.contains("\"event\":\"phone\"") && log.contains("\"ok\":false"), log)
        XCTAssertFalse(log.contains("결제하기"))
        try? FileManager.default.removeItem(atPath: dir)
    }
}
