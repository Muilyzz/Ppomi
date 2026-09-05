// Column.build against report.py column_html over the same data/shots (column-parity.json, JPEG data stripped).
import XCTest
@testable import Ppomi

final class ColumnTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("column-parity.json")

    func testEvidID() {
        XCTAssertEqual(Column.evidID("KAKAO:2026-08-29 19:18:-28000:461402"), "ev-KAKAO_2026_08_29_19_18__28000_461402")
        XCTAssertEqual(Column.esc("a<b & 'c'"), "a&lt;b &amp; &#x27;c&#x27;")
    }

    func testParityWithPython() throws {
        guard FileManager.default.fileExists(atPath: OCRTests.shots.path), let d = try? Data(contentsOf: Self.fixture)
        else { throw XCTSkip("no data/shots or column-parity.json") }
        let o = try JSONSerialization.jsonObject(with: d) as! [String: [String: Any]]
        let inDB = Set(try DB(path: LedgerTests.dbPath).transactions().map(\.uid))
        for (app, want) in o {
            XCTAssertEqual(inDB.count, want["in_db"] as? Int, "the DB the fixture was made from")
            var frames = Stitch.loadFrames(app: app, shots: OCRTests.shots)
            let placed = Stitch.place(&frames, app: app)
            let got = Column.build(app: app, placed: placed, frames: frames, inDB: inDB)
            XCTAssertEqual(got.drawn, want["ok"] as? Int, app); XCTAssertEqual(got.anomalies, want["bad"] as? Int, app)
            let html = got.html.replacingOccurrences(of: #"src="data:image/jpeg;base64,[^"]*""#, with: "src=\"\"", options: .regularExpression)
            let w = (want["col"] as! String).replacingOccurrences(of: #" title="[^"]*""#, with: "", options: .regularExpression)   // tooltips dropped on purpose
            if html != w {                                    // first differing line, so the failure reads
                let a = html.split(separator: "\n", omittingEmptySubsequences: false), b = w.split(separator: "\n", omittingEmptySubsequences: false)
                let i = Array(zip(a, b)).firstIndex { $0 != $1 } ?? min(a.count, b.count)
                XCTFail("\(app) line \(i)/\(a.count) vs \(b.count):\n got: \(i < a.count ? a[i] : "")\nwant: \(i < b.count ? b[i] : "")")
            }
        }
    }
}
