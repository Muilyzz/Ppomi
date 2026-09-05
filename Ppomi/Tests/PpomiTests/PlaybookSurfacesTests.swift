import XCTest
@testable import Ppomi

final class PlaybookSurfacesTests: XCTestCase {
    private func manifest(name: String = "새 앱") -> PlaybookManifest {
        PlaybookManifest(id: "catalog-demo", name: name, version: "1.0.0", aliases: ["Demo"],
                         launch: .init(search: "새 앱"),
                         capabilities: [.init(id: "search", title: "항목 검색", description: "조건에 맞는 항목을 찾습니다.",
                                              inputs: [.init(name: "keyword", label: "검색어", required: true)],
                                              steps: [.init(id: "open", title: "앱 열기", kind: "open"),
                                                      .init(id: "search", title: "항목 검색", kind: "input")])],
                         humanSteps: ["로그인은 직접 진행합니다."], guide: "guide.md")
    }

    func testHistoricalObservationDoesNotClaimReplaySuccess() throws {
        var footprint = Footprint(app: "catalog-demo", glyph: "⊙", target: "검색", fingerprintBefore: ["홈"], fingerprintAfter: ["검색"])
        footprint.verified.ok = 8
        let legacyData = try JSONEncoder().encode(footprint)
        let legacy = try JSONDecoder().decode(Footprint.self, from: legacyData)
        let record = PlaybookRecord(manifest: manifest(), directory: URL(fileURLWithPath: "/unused"), guideText: "사용법", iconURL: nil)
        let entry = PlaybookEntry(record: record, footprints: [legacy], installed: nil)
        XCTAssertEqual(entry.status, "현재 버전 재생 검증 전")
        XCTAssertTrue(entry.replayed.isEmpty)
        XCTAssertEqual(entry.evidence.historicalOK, 8)
        XCTAssertEqual(entry.evidence.replayOK, 0)

        footprint.verified.replayOK = 2
        footprint.verified.replayFail = 1
        footprint.verified.replayVersions = ["1.0.0": .init(ok: 2, fail: 1)]
        let updated = PlaybookEntry(record: record, footprints: [footprint], installed: nil)
        XCTAssertEqual(updated.evidence.replayedSteps, 1)
        XCTAssertEqual(updated.evidence.replayOK, 2)
        XCTAssertEqual(updated.evidence.replayFail, 1)
        XCTAssertEqual(updated.status, "현재 버전 재생 성공 1개 동작")
    }

    func testNewPlaybookVersionRequiresItsOwnReplayEvidence() throws {
        var footprint = Footprint(app: "catalog-demo", glyph: "⊙", target: "검색", fingerprintBefore: ["홈"], fingerprintAfter: ["검색"])
        footprint.verified.ok = 4
        footprint.verified.replayOK = 4
        footprint.verified.replayFail = 1
        footprint.verified.replayVersions = ["1.0.0": .init(ok: 4, fail: 1)]
        let old = PlaybookEvidence([footprint], version: "1.0.0")
        XCTAssertEqual(old.replayedSteps, 1)
        XCTAssertEqual(old.replayOK, 4)
        XCTAssertEqual(old.playbookVersion, "1.0.0")

        var updatedManifest = manifest()
        updatedManifest.version = "2.0.0"
        let updatedRecord = PlaybookRecord(manifest: updatedManifest, directory: URL(fileURLWithPath: "/unused"), guideText: "새 사용법", iconURL: nil)
        let updated = PlaybookEntry(record: updatedRecord, footprints: [footprint], installed: nil)
        XCTAssertEqual(updated.status, "현재 버전 재생 검증 전")
        XCTAssertTrue(updated.replayed.isEmpty)
        XCTAssertEqual(updated.evidence.playbookVersion, "2.0.0")
        XCTAssertEqual(updated.evidence.replayOK, 0)
        XCTAssertEqual(updated.evidence.replayFail, 0)
        XCTAssertEqual(updated.evidence.historicalOK, 4)
        XCTAssertEqual(updated.replayOK(footprint), 0)
        XCTAssertEqual(updated.replayFail(footprint), 0)
        XCTAssertEqual(PlaybookEvidence([footprint]).replayOK, 4)

        footprint.verified.replayVersions?["2.0.0"] = .init(ok: 1, fail: 0)
        let revalidated = PlaybookEntry(record: updatedRecord, footprints: [footprint], installed: nil)
        XCTAssertEqual(revalidated.evidence.replayedSteps, 1)
        XCTAssertEqual(revalidated.evidence.replayOK, 1)
        XCTAssertEqual(revalidated.replayOK(footprint), 1)
        XCTAssertEqual(revalidated.replayFail(footprint), 0)
    }

    func testManifestDrivesCardIdentityAndAgentDefinition() throws {
        let old = PlaybookRecord(manifest: manifest(), directory: URL(fileURLWithPath: "/unused"), guideText: "사용법", iconURL: nil)
        let renamed = PlaybookRecord(manifest: manifest(name: "새 이름"), directory: old.directory, guideText: old.guideText, iconURL: nil)
        XCTAssertEqual(PlaybookEntry(record: old, footprints: [], installed: nil).id,
                       PlaybookEntry(record: renamed, footprints: [], installed: nil).id)
        XCTAssertEqual(renamed.summary, "항목 검색")
        XCTAssertEqual(PlaybookEntry(record: renamed, footprints: [], installed: nil).stepCount, 2)
        let encoded = try XCTUnwrap(Playbooks.definition(renamed).data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(PlaybookManifest.self, from: encoded), renamed.manifest)
    }

    func testStableIDNotesJoinExistingNotebookAndCatalogPrompt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surface-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("catalog/catalog-demo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest()).write(to: package.appendingPathComponent("manifest.json"))
        try "# 기본 사용법\n".write(to: package.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try Playbooks.append("catalog-demo", "목록을 확인한다", in: dir)
        try Playbooks.append("DEMO", "검색 결과에서 멈춘다", in: dir)
        let notebook = dir.appendingPathComponent("새 앱.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notebook.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("catalog-demo.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("DEMO.md").path))
        let books = Playbooks.all(in: dir)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.app, "새 앱")
        XCTAssertTrue(books.first?.text.contains("목록을 확인한다") == true)
        XCTAssertTrue(books.first?.text.contains("검색 결과에서 멈춘다") == true)
        XCTAssertTrue(Playbooks.prompt(in: dir).contains("catalog-demo"))
        XCTAssertTrue(Playbooks.prompt(in: dir).contains("keyword"))
    }
}
