import XCTest
@testable import Ppomi
final class SmokeTests: XCTestCase {
    func testWon() { XCTAssertEqual(1234567.won, "1,234,567원"); XCTAssertEqual((-5).won, "−5원"); XCTAssertEqual(3.signedWon, "+3원") }
    func testTS() { XCTAssertEqual(TS.string(TS.parse("2026-08-30 22:59")!), "2026-08-30 22:59") }
}

final class MirrorTests: XCTestCase {
    func testMirrorClassify() {
        XCTAssertEqual(Mirroring.classify(["iPhone 사용 중"]), .inUse)
        XCTAssertEqual(Mirroring.classify(["연결이 중단됨", "다시 시도"]), .disconnected)
        XCTAssertEqual(Mirroring.classify(["연결이 일시 정지됨", "재개"]), .paused)
        XCTAssertEqual(Mirroring.classify(["KB스타뱅킹"]), .connected)
    }
    @MainActor func testToggleKioskRoundTrip() {
        let s = AppState(); s.mirror = .connected
        s.toggleKiosk(); XCTAssertEqual(s.phase, .humanUse(onScreen: true)); XCTAssertTrue(s.kioskOn)
        s.toggleKiosk(); XCTAssertEqual(s.phase, .idle); XCTAssertFalse(s.kioskOn)
    }
    @MainActor func testShowEvidenceSwitchesTabInWindowAndKiosk() {
        let s = AppState()
        XCTAssertEqual(s.tab, .timeline)                          // the console opens on the ledger
        s.showEvidence(); XCTAssertEqual(s.tab, .evidence)
        s.show(.playbooks); XCTAssertEqual(s.tab, .playbooks)
        s.toggleKiosk(); XCTAssertEqual(s.tab, .playbooks)     // one workbench: the ring shows what the window showed
        s.toggleKiosk(); XCTAssertEqual(s.tab, .playbooks)
    }
    @MainActor func testKioskDonutIgnoresInUse() {
        let s = AppState(); s.mirroring(.inUse)
        XCTAssertEqual(s.phase, .humanUse(onScreen: false)); XCTAssertFalse(s.kioskOn)
        s.toggleKiosk(); XCTAssertTrue(s.kioskOn)
        s.mirroring(.inUse); XCTAssertTrue(s.kioskOn)
        s.mirroring(.none); XCTAssertTrue(s.kioskOn)
    }
}

final class EvidenceDefaultDayTests: XCTestCase {
    /// ⌘E on a day with no 전표 (today) lands on the newest day that has one, like the HTML report's newest-month fallback.
    @MainActor func testShowEvidenceFallsBackToNewestDay() throws {
        let s = AppState()
        s.ledger = try Ledger.load(dbPath: LedgerTests.dbPath, me: LedgerTests.me)
        s.selectedDay = KST.day(s.ledger!.lines.map(\.ts).max()!, 30)
        s.showEvidence()
        XCTAssertEqual(KST.ymd(s.evidenceFocus!.day), KST.ymd(s.ledger!.lines.map(\.ts).max()!))
        s.showEvidence(day: s.selectedDay)                       // an explicit day is kept even when empty
        XCTAssertEqual(s.evidenceFocus!.day, s.selectedDay)
    }
}

