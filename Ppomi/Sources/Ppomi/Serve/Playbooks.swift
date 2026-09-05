// The catalog is the shared definition; local Markdown is the owner's growing notebook.
// Both the kiosk and outside agents read the same manifest and replay evidence.
import Foundation

struct PlaybookEvidence: Codable, Equatable {
    let playbookVersion: String?
    let savedSteps: Int
    let replayedSteps: Int
    let replayOK: Int
    let replayFail: Int
    let historicalOK: Int
    let historicalFail: Int

    init(_ footprints: [Footprint], version: String? = nil) {
        func successes(_ footprint: Footprint) -> Int {
            if let version { return footprint.verified.replayVersions?[version]?.ok ?? 0 }
            return footprint.verified.replayOK ?? 0
        }
        func failures(_ footprint: Footprint) -> Int {
            if let version { return footprint.verified.replayVersions?[version]?.fail ?? 0 }
            return footprint.verified.replayFail ?? 0
        }
        playbookVersion = version
        savedSteps = footprints.count
        replayedSteps = footprints.filter { successes($0) > 0 }.count
        replayOK = footprints.reduce(0) { $0 + successes($1) }
        replayFail = footprints.reduce(0) { $0 + failures($1) }
        historicalOK = footprints.reduce(0) { $0 + $1.verified.ok }
        historicalFail = footprints.reduce(0) { $0 + $1.verified.fail }
    }
}

enum Playbooks {
    static var dir: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().appendingPathComponent("playbooks") }

    /// Bundled definitions belong to the app's catalog, not to isolated caller/test directories.
    private static func records(in dir: URL) -> [PlaybookRecord] {
        PlaybookCatalog.load(in: dir, includeBundled: dir.standardizedFileURL == self.dir.standardizedFileURL)
    }

    static func evidence(_ record: PlaybookRecord, in dir: URL = dir) -> PlaybookEvidence {
        PlaybookEvidence(FootprintStore.load(record.id, in: dir), version: record.manifest.version)
    }

    static func definition(_ record: PlaybookRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(record.manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Catalog definitions plus local notebooks, with common rules first. Raw Markdown remains readable.
    static func all(in dir: URL = dir) -> [(app: String, text: String)] {
        let catalog = records(in: dir)
        var books = catalog.map { record in
            (app: record.name, text: record.guideText + "\n\n[플레이북 명세]\n" + definition(record))
        }
        let known = Set(catalog.flatMap { [$0.id, $0.name] + $0.manifest.aliases })
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard name != "공통", !known.contains(name), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            books.append((app: name, text: text))
        }
        let common = dir.standardizedFileURL == self.dir.standardizedFileURL
            ? PlaybookCatalog.common(in: dir)
            : (try? String(contentsOf: dir.appendingPathComponent("공통.md"), encoding: .utf8)) ?? ""
        if !common.isEmpty { books.append((app: "공통", text: common)) }
        return books.sorted { ($0.app == "공통" ? "" : $0.app) < ($1.app == "공통" ? "" : $1.app) }
    }

    /// Keep learned notes in the existing human-readable notebook, even when callers use the stable catalog ID.
    static func append(_ app: String, _ line: String, in dir: URL = dir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = records(in: dir).first { $0.matches(app) }
        let name = (record?.name ?? app).replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent(name + ".md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? record?.guideText ?? "# \(name)\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(KST.ymd(Date())) \(line)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func prompt(in dir: URL = dir) -> String {
        let books = all(in: dir)
        guard !books.isEmpty else { return "" }
        return "\n[앱별 절차] 공통은 모든 앱의 규칙, 플레이북 명세는 앱 ID·가능한 작업·필요한 입력·사람이 필요한 단계를 정의한다. " +
            "capabilities의 steps가 작업 순서이며 guide는 상세 사용법과 현장에서 배운 버릇이다. 문서 절차만으로 재생이 검증됐다고 판단하지 마라. " +
            "폰 앱 작업은 run_combo 먼저, 멈춘 화면부터 phone_screen/phone_tap. 새로 알게 된 버릇은 note_playbook 으로 한 줄 적어라.\n"
            + books.map { "## \($0.app)\n\($0.text)" }.joined(separator: "\n")
    }
}
