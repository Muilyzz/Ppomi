// 절차 tab: the playbooks the agent reads, listed like a tool list — app, whether the phone has it, the steps.
import SwiftUI

struct PlaybooksView: View {
    @EnvironmentObject var state: AppState
    @State private var html: String? = nil

    var body: some View {
        Group {
            if let html { WebPage(html: html) } else { ProgressView() }
        }
        .onAppear { html = Self.html() }
        .onChange(of: state.ledgerVersion) { _, _ in html = Self.html() }   // the reload button re-reads the files too
    }

    static func html() -> String {
        let db = try? DB(path: AppSettings.dbPath, writable: false)
        let rows: [[String: Any]] = Playbooks.all().map { p in
            let inst = db.flatMap { (try? $0.state("installed:\(p.app)")) ?? nil }
            return ["app": p.app, "text": p.text, "file": "data/playbooks/\(p.app).md",
                    "installed": p.app == "공통" ? "" : inst == "1" ? "설치됨" : inst == "0" ? "미설치" : "미확인"]
        }
        let json = String(data: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let tpl = Web.page("playbooks")
        return tpl.replacingOccurrences(of: "/*PLAYBOOKS*/null", with: json)
    }
}
