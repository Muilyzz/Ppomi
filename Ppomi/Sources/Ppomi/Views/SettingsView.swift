// 설정: 연결(키·주소·모델), 장부(DB 경로), 내 정보(내 이름). The key goes to the Keychain, the rest to AppSettings.
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var apiKey = ""              // only what was pasted now; the stored key is never read back into a field
    @State private var hasKey = false
    @State private var baseURL = AppSettings.baseURL
    @State private var model = AppSettings.model
    @State private var dbPath = AppSettings.dbPath
    @State private var me = AppSettings.me
    @State private var checking = false
    @State private var connection: Connection = .unknown
    @State private var items: [Permissions.Item] = []   // the 시작하기 rows, re-read every 2 s while the window is up
    @State private var telemetry = false                 // state table "telemetry:on" (Telemetry.swift reads it)
    @FocusState private var keyFocus: Bool
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Connection { case unknown, ok(String), fail(String) }

    var body: some View {
        Form {
            Section("시작하기") {
                ForEach(items) { i in
                    HStack {
                        Text(i.ok == nil ? "·" : i.ok! ? "✓" : "✗").bold().frame(width: 16)
                            .foregroundStyle(i.ok == nil ? .secondary : i.ok! ? Color.green : Color.red)
                        VStack(alignment: .leading) { Text(i.name); Text(i.note).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if !i.button.isEmpty { Button(i.button, action: i.open) }
                    }
                }
                Text(items.allSatisfy { $0.ok != false } ? "준비됐어요" : Permissions.ready ? "손과 눈은 준비됨 · 나머지는 선택" : "손쉬운 사용과 화면 기록이 있어야 움직여요")
                    .foregroundStyle(Permissions.ready ? .green : .red)
                Toggle("실행 결과 보내기 (성공/실패/걸음 번호만)", isOn: Binding(get: { telemetry }, set: { on in
                    telemetry = on
                    try? DB(path: AppSettings.dbPath, writable: true).setState("telemetry:on", on ? "1" : "0")
                }))
            }
            Section("연결") {
                SecureField("API 키", text: $apiKey, prompt: Text(hasKey ? "바꾸려면 새 키를 붙여넣기" : "키를 붙여넣기"))
                    .focused($keyFocus)
                if hasKey {
                    HStack {
                        Text("키체인에 저장됨").foregroundStyle(.secondary)
                        Spacer()
                        Button("삭제") { deleteKey() }
                    }
                }
                TextField("기본 URL", text: $baseURL)
                TextField("모델", text: $model)
                HStack {
                    Button("저장하고 확인") { Task { await saveAndCheck() } }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    connectionText
                }
            }
            Section("장부") {
                TextField("DB 경로", text: $dbPath)
                    .onChange(of: dbPath) { _, new in AppSettings.dbPath = new }
                HStack { ledgerText }
            }
            Section("내 정보") {
                TextField("내 이름", text: $me)
                    .onChange(of: me) { _, new in AppSettings.me = new }
                Text("이 이름으로 들어온 입금은 내 계좌 사이의 이체로 읽습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            hasKey = Keychain.apiKey() != nil
            telemetry = (try? DB(path: AppSettings.dbPath).state("telemetry:on")) == "1"
            recheckItems()
        }
        .onReceive(recheck) { _ in recheckItems() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheckItems() }   // back from System Settings: re-read at once
    }

    private func recheckItems() { items = Permissions.items { keyFocus = true } }

    @ViewBuilder private var connectionText: some View {
        switch connection {
        case .unknown: EmptyView()
        case .ok(let s): Text(s).foregroundStyle(.secondary)
        case .fail(let s): Text(s).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var ledgerText: some View {
        if let e = state.ledgerError { Text(e).foregroundStyle(.red).lineLimit(2) }
        else if let l = state.ledger { Text("계좌 \(l.accounts.count)개 · 분개 \(l.lines.count)줄").foregroundStyle(.secondary) }
    }

    private func deleteKey() {
        do { try Keychain.deleteAPIKey(); hasKey = false; connection = .unknown }
        catch { connection = .fail(error.localizedDescription) }
    }

    /// Persist URL/model/key, then prove the connection: GET /models, and on a Vercel gateway also GET /credits.
    @MainActor private func saveAndCheck() async {
        checking = true
        defer { checking = false }
        AppSettings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            do { try Keychain.setAPIKey(pasted); apiKey = ""; hasKey = true }
            catch { connection = .fail(error.localizedDescription); return }
        }
        guard let key = Keychain.apiKey() else { connection = .fail("API 키가 없음"); return }
        guard let url = URL(string: AppSettings.baseURL), let host = url.host else { connection = .fail("기본 URL이 올바르지 않음"); return }
        let client = LLMClient(baseURL: url, apiKey: key)
        do {
            var line = "연결됨 · \(try await client.listModels().count)개 모델"
            if host.contains("vercel"), let balance = try? await client.credits().balance {
                line += " · 남은 예산 $\(String(format: "%.2f", balance))"
            }
            connection = .ok(line)
        } catch {
            connection = .fail(error.localizedDescription)
        }
    }
}
