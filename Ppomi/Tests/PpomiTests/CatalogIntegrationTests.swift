import XCTest
@testable import Ppomi

final class CatalogIntegrationTests: XCTestCase {
    private var root: URL!
    private var runtime: URL { root.appendingPathComponent("playbooks") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        Tools.fake = nil
        try FileManager.default.removeItem(at: root)
    }
    private func install(name: String = "새로운 앱", aliases: [String] = ["원래 이름"]) throws -> PlaybookRecord {
        let source = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = PlaybookManifest(id: "example2", name: name, version: "1.0.0", aliases: aliases,
            launch: .init(search: "example search"), capabilities: [
                .init(id: "browse", title: "목록 조회", description: "데이터로 추가한 앱", inputs: [], steps: [
                    .init(id: "open", title: "앱 열기", kind: "open"), .init(id: "read", title: "목록 보기", kind: "read")])
            ], humanSteps: ["로그인은 사람이 진행합니다."], guide: "guide.md")
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        try "# 사용법\n목록을 확인합니다.".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        return try PlaybookCatalog.install(from: source, in: runtime)
    }
    private func words(_ texts: [String]) -> [OCR.Word] {
        texts.enumerated().map { .init(x: 0.1, y: Double($0) / 10, w: 0.3, h: 0.02, text: $1) }
    }
    private func tools() throws -> Tools {
        let tools = try Tools(db: try DB(path: root.appendingPathComponent("ledger.db").path, writable: true))
        tools.currentText = "진행해"; tools.footprintDir = runtime
        return tools
    }

    func testImportedAppOpensByIDAndReplaysTheSameDefinition() throws {
        let record = try install(), tool = try tools()
        var texts = ["새로운 앱", "목록 보기"], hands: [[String]] = []
        Tools.fake = (screen: { self.words(texts) }, hand: { hands.append($0) })
        tool.lastWords = words(["검색 화면", "앱 목록"])
        XCTAssertEqual(tool.execute("phone_open", ["app": record.id]), "열었다.")
        XCTAssertEqual(hands, [["open", record.name]])
        XCTAssertEqual(tool.currentApp, "example2")
        XCTAssertEqual(try tool.db.state("installed:example2"), "1")
        let saved = try XCTUnwrap(FootprintStore.load("원래 이름", in: runtime).first)
        XCTAssertEqual(saved.app, record.id)
        XCTAssertEqual(saved.target, record.id) // IDs containing digits are metadata, never typed personal data.
        XCTAssertEqual(Playbooks.evidence(record, in: runtime).replayOK, 0)

        texts = ["검색 화면", "앱 목록"]
        Tools.fake = (screen: { self.words(texts) }, hand: { move in hands.append(move); texts = ["새로운 앱", "목록 보기"] })
        let result = tool.execute("run_combo", ["app": "원래 이름", "max_steps": 1])
        XCTAssertTrue(result.contains("▶ example2 ✓"), result)
        XCTAssertEqual(hands.last, ["open", record.name])
        XCTAssertEqual(Playbooks.evidence(record, in: runtime).replayOK, 1)
        XCTAssertEqual(Playbooks.evidence(record, in: runtime).replayedSteps, 1)
    }

    func testLegacyEvidenceMergesOnceAndSurvivesAppRename() throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let legacy = Footprint(app: "원래 이름", glyph: "⊙", target: "목록", fingerprintBefore: ["시작"], fingerprintAfter: ["목록"])
        try FootprintStore.append("원래 이름", legacy, in: runtime)
        let legacyFile = runtime.appendingPathComponent("원래 이름.jsonl"), original = try Data(contentsOf: legacyFile)
        _ = try install()
        XCTAssertEqual(FootprintStore.url("원래 이름", in: runtime).lastPathComponent, "example2.jsonl")
        try FootprintStore.bump("example2", id: legacy.id, ok: true, in: runtime)
        XCTAssertEqual(FootprintStore.load("example2", in: runtime).count, 1)
        XCTAssertNil(FootprintStore.load("example2", in: runtime)[0].verified.replayOK)
        let renamed = try install(name: "바뀐 이름", aliases: ["원래 이름", "새로운 앱"])
        try FootprintStore.bump(renamed.name, id: legacy.id, ok: false, replay: true, in: runtime)
        let merged = FootprintStore.load("새로운 앱", in: runtime)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].verified.ok, 1)
        XCTAssertEqual(merged[0].verified.replayFail, 1)
        XCTAssertEqual(try Data(contentsOf: legacyFile), original)
    }

    func testOldVerificationJSONDoesNotAcquireReplayEvidence() throws {
        let old = Data(#"{"ok":7,"fail":2}"#.utf8)
        let value = try JSONDecoder().decode(Footprint.Verified.self, from: old)
        XCTAssertEqual(value.ok, 7); XCTAssertEqual(value.fail, 2)
        XCTAssertNil(value.replayOK); XCTAssertNil(value.replayFail)
    }

    func testNewAppWithoutFootprintsBecomesTheRecordingContext() throws {
        _ = try install()
        let tool = try tools()
        tool.currentApp = "이전 앱"
        var screens = [["목록 화면", "상세 보기"], ["상세 화면", "돌아가기"]]
        Tools.fake = (screen: { self.words(screens.count > 1 ? screens.removeFirst() : screens[0]) }, hand: { _ in })
        XCTAssertTrue(tool.execute("run_combo", ["app": "원래 이름"]).hasPrefix("아는 길 없음: example2"))
        XCTAssertEqual(tool.currentApp, "example2")
        XCTAssertTrue(tool.execute("phone_tap", ["text": "상세 보기"]).hasPrefix("탭했다"))
        XCTAssertEqual(FootprintStore.load("example2", in: runtime).count, 1)
        XCTAssertEqual(FootprintStore.load("이전 앱", in: runtime).count, 0)
    }

    func testInstallationCheckUsesImportedSearchAndNeverAssumesPresence() throws {
        _ = try install()
        let tool = try tools()
        var hands: [[String]] = []
        Tools.fake = (screen: { self.words(["새로운 앱", "받기"]) }, hand: { hands.append($0) })
        XCTAssertEqual(tool.execute("phone_installed", ["names": "example2"]), "새로운 앱: 미설치(App Store 받기)")
        XCTAssertTrue(hands.contains(["type", "example search"]))
        XCTAssertEqual(try tool.db.state("installed:example2"), "0")
    }
}
