// load_frames + stitch against what report.py computed over the same data/shots (stitch-parity.json).
import XCTest
@testable import Ppomi

final class StitchTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("stitch-parity.json")

    func testAnchor() {
        XCTAssertEqual(Stitch.anchor("13:06 # 체크카드 530,919원"), "13:06|530,919")
        XCTAssertEqual(Stitch.anchor("13:06 #체크카드 530,919원"), "13:06|530,919")
        XCTAssertEqual(Stitch.anchor("08.24 21:56:29 I 스마트출금"), "08|24|21|56|스마트출금")
        XCTAssertNil(Stitch.anchor("쿠팡이츠 -37,000원"))
    }

    func testParityWithPython() throws {
        guard FileManager.default.fileExists(atPath: OCRTests.shots.path), let d = try? Data(contentsOf: Self.fixture)
        else { throw XCTSkip("no data/shots or stitch-parity.json") }
        let o = try JSONSerialization.jsonObject(with: d) as! [String: [String: Any]]
        for (app, want) in o {
            var frames = Stitch.loadFrames(app: app, shots: OCRTests.shots)
            let placed = Stitch.place(&frames, app: app)
            let wf = want["frames"] as! [[String: Any]], wp = want["placed"] as! [[String: Any]]
            XCTAssertEqual(frames.map(\.png.lastPathComponent), wf.map { $0["png"] as! String }, app)
            for (f, w) in zip(frames, wf) {
                XCTAssertEqual(f.run, w["run"] as? Int, f.png.lastPathComponent)
                XCTAssertEqual(f.keys, w["keys"] as? [String: Int], f.png.lastPathComponent)
                XCTAssertEqual(f.tx.map { "\($0.uid) \($0.rows.lowerBound)-\($0.rows.upperBound)" },
                               (w["tx"] as! [[String: Any]]).map { "\($0["uid"]!) \(($0["rows"] as! [Int])[0])-\(($0["rows"] as! [Int])[1])" }, f.png.lastPathComponent)
                for (y, wy) in zip(f.ys, w["ys"] as! [[Double]]) { XCTAssertEqual(y.0, wy[0], accuracy: 1e-12); XCTAssertEqual(y.1, wy[1], accuracy: 1e-12) }
            }
            XCTAssertEqual(placed.map { frames[$0.frame].png.lastPathComponent }, wp.map { $0["png"] as! String }, app)
            for (p, w) in zip(placed, wp) {
                XCTAssertEqual(p.top, w["top"] as! Double, accuracy: 1e-9, "top \(w["png"]!)")
                XCTAssertEqual(p.clip, w["clip"] as! Double, accuracy: 1e-9, "clip \(w["png"]!)")
                XCTAssertEqual(p.bottom, w["bottom"] as! Double, accuracy: 1e-9, "bottom \(w["png"]!)")
            }
        }
    }
}
