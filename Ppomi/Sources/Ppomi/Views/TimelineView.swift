// 타임라인: the net-worth step line, the accounting equation per day, and the selected day's balance sheets and journal —
// Web/timeline.html (report.py's TIMELINE_JS as it was) fed by the ledger this app read; the workbench's first tab.
import SwiftUI

enum Timeline {
    /// The page's data in the shape report.py timeline_data made (Tests/timeline-parity.json), plus uid per line.
    static func data(_ L: Ledger) -> [String: Any] {
        ["accounts": L.accounts.map { ["id": $0.id, "app": $0.title] },
         "series": L.series.mapValues { $0.map { [TS.string($0.ts), $0.value, $0.how.rawValue] as [Any] } },
         "inside": Array(L.defaultLens.inside).sorted(),
         "lines": L.lines.map { ["ts": TS.string($0.ts), "memo": $0.memo, "dr": $0.dr, "cr": $0.cr, "amount": $0.amount, "rev": $0.rev, "uid": $0.uid] }]
    }

    static func html(_ L: Ledger) -> String {
        let json = String(data: try! JSONSerialization.data(withJSONObject: data(L)), encoding: .utf8)!   // "/" is escaped: no "</script>" can leak
        let tpl = Web.page("timeline")
        return tpl.replacingOccurrences(of: "/*TIMELINE*/null", with: json)
    }
}

struct TimelineView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let L = state.ledger { WebPage(html: Timeline.html(L), onMessage: handle) }
            else {
                ContentUnavailableView(state.ledgerError == nil ? "장부 없음 · 설정에서 경로 확인" : "장부를 읽지 못함",
                                       systemImage: "book.closed", description: Text(state.ledgerError ?? AppSettings.dbPath))
            }
        }
        .onAppear { if state.ledger == nil { state.reloadLedger() } }
    }

    /// {day: "YYYY-MM-DD"} follows the page's selected day; {evidence: uid} opens that voucher's 증빙.
    private func handle(_ m: Any) {
        guard let m = m as? [String: Any] else { return }
        let day = (m["day"] as? String).flatMap { TS.parse($0 + " 00:00") }
        if let day { state.selectedDay = day }
        if let uid = m["evidence"] as? String {
            state.showEvidence(day: day, uid: uid)
        }
    }
}
