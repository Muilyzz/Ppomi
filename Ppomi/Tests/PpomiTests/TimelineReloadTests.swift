import Combine
import XCTest
@testable import Ppomi

final class TimelineReloadTests: XCTestCase {
    /// Raw HTML equality controls WKWebView navigation; dictionary iteration must not reload unchanged ledger data.
    func testRepeatedRenderingOfUnchangedLedgerProducesIdenticalHTML() throws {
        let ledger = syntheticLedger()
        let expected = Timeline.html(ledger)
        for _ in 0..<100 {
            XCTAssertTrue(Timeline.html(ledger) == expected, "Unchanged ledger unexpectedly changed the page bytes")
        }
        var changed = ledger
        changed.lines[0] = JournalLine(id: "line-0", ts: ledger.lines[0].ts, memo: "Synthetic", dr: "account-0",
                                       cr: "external", amount: 999, rev: false, inferred: false, uid: "uid-0")
        XCTAssertNotEqual(Timeline.html(changed), expected)
    }

    @MainActor func testInitialDayMessageDoesNotPublishUnchangedSelection() throws {
        let state = AppState()
        state.selectedDay = try XCTUnwrap(TS.parse("2026-09-01 00:00"))
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        withExtendedLifetime(subscription) {
            for _ in 0..<100 { Timeline.receive(["day": "2026-09-01"], state: state) }
            XCTAssertEqual(publications, 0)
            Timeline.receive(["day": "2026-09-02"], state: state)
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(KST.ymd(state.selectedDay), "2026-09-02")
            Timeline.receive(["day": "2026-09-02"], state: state)
            XCTAssertEqual(publications, 1)
        }
    }

    @MainActor func testEvidenceMessageStillNavigatesWhenDayIsUnchanged() throws {
        let state = AppState()
        let day = try XCTUnwrap(TS.parse("2026-09-01 00:00"))
        state.selectedDay = day
        Timeline.receive(["day": "2026-09-01", "evidence": "synthetic-voucher"], state: state)
        XCTAssertEqual(state.tab, .evidence)
        XCTAssertEqual(state.evidenceFocus?.day, day)
        XCTAssertEqual(state.evidenceFocus?.uid, "synthetic-voucher")
    }

    private func syntheticLedger() -> Ledger {
        let date = Date(timeIntervalSince1970: 1_788_220_800)
        let ids = (0..<8).map { "account-\($0)" }
        return Ledger(
            accounts: ids.map { Account(id: $0, app: "TEST", title: "Synthetic") },
            series: Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
                (id, (0..<3).map { Observation(ts: date.addingTimeInterval(Double($0 * 3600)), value: index * 100 + $0, how: .snapshot) })
            }),
            lines: (0..<10).map { JournalLine(id: "line-\($0)", ts: date, memo: "Synthetic", dr: ids[$0 % ids.count],
                                              cr: "external", amount: $0, rev: false, inferred: false, uid: "uid-\($0)") },
            defaultLens: Lens(name: "Synthetic", inside: Set(ids)))
    }
}
