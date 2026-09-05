// The app's state: who has the phone, what the mirroring window reports, and the one derived value the screen needs (donut).
import Foundation
import Combine

/// Who has the phone. "평소" is not a phone state: it is what the person does on the Mac in any state.
enum Phase: Equatable {
    case idle                                   // nobody; the phone is locked nearby (connectable) or away
    case agent(job: String)                     // the agent is driving the phone ("KB 읽는 중 3/4")
    case humanTurn(reason: String)              // the agent is waiting for a specific human action ("폰에서 승인해 주세요")
    case humanUse(onScreen: Bool)               // the person uses the phone: in hand (IN_USE) or on the big screen (asked for it)
}

/// What the mirroring window's accessibility tree says (see Mirroring.swift).
enum MirrorState: String { case connected = "CONNECTED", disconnected = "DISCONNECTED", paused = "PAUSED", inUse = "IN_USE", none = "NONE" }

@MainActor
final class AppState: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var mirror: MirrorState = .none
    @Published var pendingJob: String? = nil    // an agent job interrupted by the human picking the phone up; resumes on CONNECTED
    @Published var kioskOn = false              // the person asked for the phone on the whole screen (humanUse(onScreen: true))
    @Published var phoneSize = Mirroring.defaultSize   // the mirroring window's size: the dock pane in the 뽀미 window is this big
    @Published var shown = 0                    // bumps when a menu item wants the 뽀미 window up (the controller owns it)

    func reveal() { shown += 1 }
    @Published var ledger: Ledger? = nil        // read from data/ledger.db (am.py writes it); nil until loaded
    @Published var ledgerError: String? = nil
    @Published var ledgerVersion = 0                    // bumps on every (re)load, so pages built from the ledger rebuild
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @Published var evidenceFocus: EvidenceFocus? = nil   // the 증빙·전표 window; nil until first open
    enum Tab { case timeline, evidence, playbooks }
    @Published var tab: Tab = .timeline                  // what the workbench shows — the window and the kiosk band alike
    @Published var voiceOn = false                       // the "뽀미야" listener (menu switch; this session only, not saved)
    @Published var listening = false                     // a voice conversation is open (after 뽀미야, until 그만 or 25 s quiet)
    @Published var heard = ""                            // the last thing the person said (voice transcript), second caption line
    @Published var said = ""                             // the last thing 뽀미 said, third caption line
    /// A question from another process (the MCP server) or the voice session's tools, waiting for a button on the ring.
    @Published var ask: (id: String, text: String, options: [String])? = nil
    private var askDB: DB?, askTimer: Timer?, answered: String?   // answered: the id we already pressed, until askViaDB clears it
    @Published var greetOnArrival = true                 // 뽀미 speaks first when the phone reconnects (menu; state table "greet:on")
    @Published var voiceToggle = 0                       // bumps: open/close the realtime session (⌥Space, the menu) — VoiceSession listens
    @Published var setupNeeded = 0                       // bumps: a phone tool was refused for missing 손·눈 (state table "setup:needed") — StartupCheck opens 설정 › 시작하기
    @Published var voiceOpen = 0                         // bumps: open it (`Ppomi --voice` left "voice:open" in the state table)

    func talk() { voiceToggle += 1 }
    func toggleGreet() { greetOnArrival.toggle(); try? askDB?.setState("greet:on", greetOnArrival ? "1" : "0") }

    /// Poll the state table every second (Tools.askViaDB leaves questions there, `--voice` its trigger); a new question turns
    /// the rim white and shows the window.
    func watchAsks(dbPath: String = AppSettings.dbPath) {
        askTimer?.invalidate()
        do { askDB = try DB(path: dbPath, writable: true) } catch { print("ask: \(error)"); return }
        greetOnArrival = ((try? askDB?.state("greet:on")) ?? nil) != "0"
        askTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.pollAsk() } }
    }
    func pollAsk() {
        guard let db = askDB else { return }
        if ((try? db.state("voice:open")) ?? nil) != nil { try? db.exec("DELETE FROM state WHERE key = 'voice:open'", []); voiceOpen += 1 }
        if ((try? db.state("setup:needed")) ?? nil) != nil { try? db.exec("DELETE FROM state WHERE key = 'setup:needed'", []); setupNeeded += 1 }
        guard let q = Tools.pendingQuestion(db), q.id != answered else {
            if ask != nil { ask = nil; if case .humanTurn = phase { phase = .idle } }
            return
        }
        guard ask?.id != q.id else { return }
        ask = (q.id, HTML.plain(q.html).replacingOccurrences(of: "\n", with: " · "), q.options)
        if case .humanUse = phase {} else { phase = .humanTurn(reason: "승인 대기 · 폰 아래 버튼") }
        if !kioskOn { reveal() }
    }
    /// A button on the ring was pressed: the answer goes back through the state table.
    func answer(_ text: String) {
        guard let a = ask, let db = askDB else { return }
        Tools.answer(db, id: a.id, text)
        answered = a.id; ask = nil
        if case .humanTurn = phase { phase = .idle }
    }

    /// Switch the workbench's tab (증빙 goes through showEvidence so it lands on a day that has 전표).
    func show(_ t: Tab) { if t == .evidence { showEvidence() } else { tab = t } }

    func showEvidence(day: Date? = nil, uid: String? = nil) {
        // No day named: the timeline's day, unless it has no 전표 (today, usually) — then the newest day that has some.
        var d = day ?? selectedDay
        if day == nil, let L = ledger, !L.lines.contains(where: { (d..<KST.day(d, 1)).contains($0.ts) }),
           let last = L.lines.map(\.ts).max() { d = Calendar.current.startOfDay(for: last) }
        evidenceFocus = EvidenceFocus(day: d, uid: uid)
        tab = .evidence
    }

    /// (Re)read the ledger. Cheap (tens of KB), so callers may do it after every collection.
    func reloadLedger() {
        do { ledger = try Ledger.load(dbPath: AppSettings.dbPath, me: AppSettings.me); ledgerError = nil }
        catch { ledgerError = "\(error)" }
        ledgerVersion += 1
    }

    /// The donut follows the kiosk switch only. Phase/IN_USE do not get a vote — that graph hid the ring
    /// while the person was looking at the mirroring window (iPhone 사용 중).
    var donut: Bool { kioskOn }

    /// The phone caption (bottom band) and the menu's first line.
    var statusLine: String {
        if listening { return "대화 중 · " + phaseLine }
        if case .idle = phase, !Permissions.ready { return "손과 눈 권한이 아직 없어요 · 설정 › 시작하기" }
        if case .idle = phase, voiceOn { return phaseLine + " · 뽀미야 라고 부르면 들음" }
        return phaseLine
    }
    private var phaseLine: String {
        switch phase {
        case .idle, .humanUse(true):
            switch mirror {
            case .connected: return "폰 연결됨 · 대기"
            case .none: return "미러링 없음"
            case .inUse: return "손에 든 iPhone · 잠그면 돌아옴"
            default: return "연결 끊김 · 20초마다 다시 시도"       // MirrorWatcher presses 다시 시도 every 20 s
            }
        case .agent(let job): return "뽀미가 \(job) 중"
        case .humanTurn(let r): return r
        case .humanUse: return "손에 든 iPhone · 잠그면 돌아옴" + (pendingJob.map { " · 이어서 \($0)" } ?? "")
        }
    }
    var menuIcon: String {
        switch phase { case .idle: return "circle"; case .agent: return "circle.fill"; case .humanTurn: return "hand.raised.fill"; case .humanUse: return "iphone" }
    }

    /// Menu, green zoom, ⌃⌘F, and the kiosk's press-to-exit. The donut is this bit; phase is only the status line.
    func toggleKiosk() {
        kioskOn.toggle()
        if kioskOn { phase = .humanUse(onScreen: true) }
        else {
            if case .humanUse = phase { phase = pendingJob.map { .agent(job: $0) } ?? .idle; pendingJob = nil }
        }
    }

    /// Feed a mirroring event. The transitions of the table in the design notes.
    func mirroring(_ s: MirrorState) {
        mirror = s
        switch (s, phase) {
        case (.inUse, .agent(let job)): pendingJob = job; phase = .humanUse(onScreen: false)
        case (.inUse, .idle): phase = .humanUse(onScreen: false)
        case (.connected, .humanUse(false)):
            if let job = pendingJob { pendingJob = nil; phase = .agent(job: job) } else { phase = kioskOn ? .humanUse(onScreen: true) : .idle }
        case (.connected, .humanTurn): phase = pendingJob.map { .agent(job: $0) } ?? .idle; pendingJob = nil
        default: break
        }
    }
}
