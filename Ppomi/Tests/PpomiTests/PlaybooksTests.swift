import XCTest
@testable import Ppomi

final class PlaybooksTests: XCTestCase {
    func testAppendMakesFileAndPromptReadsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString)")
        XCTAssertEqual(Playbooks.prompt(in: dir), "")                                   // no files: no section
        try Playbooks.append("여기어때", "객실 제목을 탭하면 요금 상세 시트가 열린다", in: dir)
        try Playbooks.append("공통", "먼저 폰 잠금을 묻는다", in: dir)
        let all = Playbooks.all(in: dir)
        XCTAssertEqual(all.map(\.app), ["공통", "여기어때"])                                // 공통 first
        XCTAssertTrue(all[1].text.hasPrefix("# 여기어때\n- "))
        XCTAssertTrue(Playbooks.prompt(in: dir).contains("## 여기어때"))
        try? FileManager.default.removeItem(at: dir)
    }
}
