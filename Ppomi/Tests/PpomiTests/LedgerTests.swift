// Parity with report.py over the real data/ledger.db (skipped when it is absent). The numbers were established by
// running timeline_data() + the timeline JS's valueAt/flows/observed in Python with STYLE_ME set to the own name (read here through AppSettings.me, never spelled out in the repo).
import XCTest
@testable import Ppomi

final class LedgerTests: XCTestCase {
    /// ../data/ledger.db relative to the package (Ppomi/Tests/PpomiTests/LedgerTests.swift → AssetManager/data/ledger.db).
    static let dbPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data/ledger.db").path
    /// Own name the ledger was built with: Settings, else STYLE_ME from the environment or the repo .env (what am.py uses).
    static let me = AppSettings.me

    func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: Self.dbPath), !Self.me.isEmpty else { throw XCTSkip("no ledger.db at \(Self.dbPath) or no STYLE_ME") }
        return try Ledger.load(dbPath: Self.dbPath, me: Self.me)
    }
    func d(_ s: String) -> Date { TS.parse(s)! }
    var august: Range<Date> { d("2026-08-01 00:00")..<d("2026-09-01 00:00") }

    func testAugustLineCount() throws {
        XCTAssertEqual(try load().lines.filter { august.contains($0.ts) }.count, 30)
    }

    func testAugustFlowsUnderDefaultLens() throws {
        let L = try load()
        var n: [Flow: Int] = [:]
        for (_, k) in L.flows(in: august, lens: L.defaultLens).lines { n[k, default: 0] += 1 }
        XCTAssertEqual(n[.transfer], 8); XCTAssertEqual(n[.conversion], 20); XCTAssertEqual(n[.income], 1); XCTAssertEqual(n[.reversal], 1)
    }

    /// observed − (income − spend) = what the ledger did not see: the 1,000,000 own-name deposits arrive from an unobserved account.
    func testAccountingEquationPerDay() throws {
        let L = try load()
        for (day, next, unobserved) in [("2026-08-30", "2026-08-31", 1_000_000), ("2026-08-31", "2026-09-01", 2_000_000)] {
            let r = d(day + " 00:00")..<d(next + " 00:00")
            let f = L.flows(in: r, lens: L.defaultLens)
            XCTAssertEqual(L.observedChange(in: r).sum - (f.income - f.spend), unobserved, day)
        }
    }

    /// 22:59 on 08-30 holds a deposit and a spend listed newest-first; the chain order puts the spend last, so its balance is the day's end.
    func testValueAtRespectsChainOrder() throws {
        let L = try load()
        XCTAssertEqual(L.value(of: "AI 관련 지출 통장", at: d("2026-08-31 00:00"))?.value, 989_222)
        XCTAssertEqual(L.value(of: "AI 관련 지출 통장", at: d("2026-08-30 00:00"))?.value, 461_402)
    }

    func testAccountLabels() throws {
        let ids = Set(try load().accounts.map(\.id))
        XCTAssert(ids.contains("KB국민ONE통장-보통예금")); XCTAssert(ids.contains("AI 관련 지출 통장"))
    }

    func testChainOrderSameMinute() {
        func tx(_ id: Int, _ ts: String, _ kind: Transaction.Kind, _ amount: Int, _ cum: Int) -> Transaction {
            Transaction(id: id, ts: d(ts), kind: kind, amount: amount, merchant: "", tag: "", cumulative: cum, app: "KAKAO", uid: "\(id)")
        }
        let prev = tx(1, "2026-08-30 19:39", .approval, 124_298, 145_156)
        let spend = tx(2, "2026-08-30 22:59", .approval, 155_934, 989_222), dep = tx(3, "2026-08-30 22:59", .deposit, 1_000_000, 1_145_156)
        XCTAssertEqual(Rules.chainOrder([prev, spend, dep]).map(\.id), [1, 3, 2])     // 145,156 + 1,000,000 − 155,934 = 989,222
        XCTAssertEqual(Rules.chainOrder([spend, dep]).map(\.id), [2, 3])              // no previous balance: left as is
    }

    /// Python `ME in m` compares code points: a decomposed (NFD) own name is not the own name, so the deposit stays 수입(미분류).
    func testOwnNameIsCodePointLiteral() {
        let nfd = "홍길동".decomposedStringWithCanonicalMapping
        let dep = Transaction(id: 1, ts: d("2026-08-31 16:04"), kind: .deposit, amount: 1, merchant: nfd, tag: "", cumulative: nil, app: "KAKAO", uid: "x")
        XCTAssertEqual(Rules.journal([dep], me: Self.me).first?.cr, "수입(미분류)")
        XCTAssertEqual(Rules.journal([dep], me: nfd).first?.cr, "내 다른 계좌(미확인)")
    }
}
