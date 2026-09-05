// The collector's pieces that run without a phone: the writable DB and the app table (same regexes as am.py APPS).
import XCTest
@testable import Ppomi

final class CollectTests: XCTestCase {
    func testWritableDBRoundTrip() throws {
        let path = NSTemporaryDirectory() + "ppomi-test-\(UUID().uuidString)/ledger.db"
        let db = try DB(path: path, writable: true)
        try db.insertSnapshot(ts: "2026-09-03 10:00", app: "KAKAO", account: "AI 관련 지출 통장", balance: 565652, shot: "x.png")
        let t = OCR.Tx(ts: "2026-09-02 15:50", kind: "approval", amount: 37000, merchant: "쿠팡이츠", card: "체크카드", cumulative: 565652,
                       uid: "KAKAO:2026-09-02 15:50:-37000:565652", rows: 0...1)
        XCTAssertTrue(try db.insertTransaction(t, app: "KAKAO"))
        XCTAssertFalse(try db.insertTransaction(t, app: "KAKAO"), "same uid twice is ignored")
        try db.setState("k", "v"); XCTAssertEqual(try db.state("k"), "v")
        let r = try DB(path: path)
        XCTAssertEqual(try r.snapshots().map(\.balance), [565652])
        XCTAssertEqual(try r.transactions().map(\.uid), [t.uid])
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func testHangulKeys() {
        XCTAssertEqual(Phone.keys(for: "여기어때"), "durldjEo"); XCTAssertEqual(Phone.keys(for: "타니베이"), "xkslqpdl")
        XCTAssertEqual(Phone.keys(for: "야놀자"), "dishfwk"); XCTAssertEqual(Phone.keys(for: "KB 국민"), "KB rnrals"); XCTAssertEqual(Phone.keys(for: "닭"), "ekfr")
    }

    func testAppsMatchPython() throws {
        let f = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("apps-parity.json")
        guard let d = try? Data(contentsOf: f) else { throw XCTSkip("no apps-parity.json") }
        let py = try JSONSerialization.jsonObject(with: d) as! [[String: Any]]
        XCTAssertEqual(Apps.all.map(\.key), py.map { $0["key"] as! String })
        for (a, p) in zip(Apps.all, py) {
            XCTAssertEqual(a.account, p["account"] as? String, a.key); XCTAssertEqual(a.title, p["title"] as? String)
            XCTAssertEqual(a.tx, p["tx"] as? String); XCTAssertEqual(a.home, p["home"] as? String); XCTAssertEqual(a.list, p["list"] as? String)
        }
    }
}
