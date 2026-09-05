// App playbooks: how 뽀미 drives each phone app (공통, 여기어때, …) — this app's asset. Markdown files in data/playbooks,
// read into the system prompt every turn, shown in the 절차 tab, grown by the agent (note_playbook) as it learns a quirk.
// The person edits the files with any editor; the tab shows what the agent reads.
import Foundation

enum Playbooks {
    static var dir: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().appendingPathComponent("playbooks") }

    /// (app, markdown) for every file: 공통 first, then by name.
    static func all(in dir: URL = dir) -> [(app: String, text: String)] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }
        let key = { (a: String) in a == "공통" ? "" : a }
        return files.compactMap { u in (try? String(contentsOf: u, encoding: .utf8)).map { (app: u.deletingPathExtension().lastPathComponent, text: $0) } }
            .sorted { key($0.app) < key($1.app) }
    }

    /// One dated line appended to the app's file (made if missing).
    static func append(_ app: String, _ line: String, in dir: URL = dir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = app.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        let u = dir.appendingPathComponent(name + ".md")
        var s = (try? String(contentsOf: u, encoding: .utf8)) ?? "# \(name)\n"
        if !s.hasSuffix("\n") { s += "\n" }
        s += "- \(KST.ymd(Date())) \(line)\n"
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    /// The system-prompt section; empty when there are no files.
    static func prompt(in dir: URL = dir) -> String {
        let ps = all(in: dir)
        guard !ps.isEmpty else { return "" }
        return "\n[앱별 절차] 공통은 콤보 표기의 뜻과 모든 앱의 규칙, 각 앱의 '콤보:' 줄이 그 앱의 기본 순서(격투 게임 커맨드처럼 왼쪽부터), 그 아래 줄들이 그 앱의 버릇이다. " +
            "폰 앱 작업은 run_combo 먼저, 멈춘 화면부터 phone_screen/phone_tap. 절차에 없는 앱의 버릇을 새로 알게 되면 note_playbook 으로 한 줄 적어라.\n"
            + ps.map { "## \($0.app)\n\($0.text)" }.joined(separator: "\n")
    }
}
