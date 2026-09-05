import SwiftUI
import AppKit

/// Local procedures and replay evidence are deliberately separate: a document is not a successful run.
struct PlaybookEntry: Identifiable {
    let app: String
    let text: String
    let footprints: [Footprint]
    let installed: String?
    var id: String { app }
    var verified: [Footprint] { footprints.filter { $0.verified.ok > 0 } }
    var steps: [String] {
        (text.components(separatedBy: "\n").first { $0.hasPrefix("콤보:") } ?? "")
            .replacingOccurrences(of: "콤보:", with: "").components(separatedBy: "›")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var summary: String {
        switch app {
        case "여기어때": return "숙소 탐색 · 객실 비교 · 예약 준비"
        case "케이뱅크": return "계좌 잔액 읽기"
        case "토스": return "연결된 자산의 잔액 읽기"
        case "KB스타뱅킹", "카카오뱅크": return "계좌 잔액 · 거래내역 읽기"
        default: return "저장된 앱 절차 살펴보기"
        }
    }
    var status: String { verified.isEmpty ? "재생 검증 전" : "성공 기록 \(verified.count)개 동작" }
    var installation: String { installed == "1" ? "설치 확인됨" : installed == "0" ? "미설치" : "설치 여부 미확인" }
    var icon: String? { ["카카오뱅크": "KAKAO", "토스": "TOSS", "KB스타뱅킹": "KB", "케이뱅크": "KBANK"][app] }
}

struct PlaybooksView: View {
    @EnvironmentObject var state: AppState
    @State private var entries: [PlaybookEntry] = []
    @State private var common = ""
    @State private var selected: String?
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("앱 플레이북").font(.title2.bold())
                        Text("뽀미가 아는 절차와 실제로 재생한 동작").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: reload) { Image(systemName: "arrow.clockwise") }.help("플레이북 새로고침")
                }
                if let entry = entries.first(where: { $0.id == selected }) {
                    Button { selected = nil } label: { Label("모든 앱", systemImage: "chevron.left") }
                    detail(entry)
                } else {
                    if entries.isEmpty {
                        ContentUnavailableView("저장된 플레이북이 없습니다", systemImage: "books.vertical", description: Text("앱별 절차를 기록하면 여기에 표시됩니다."))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(entries) { entry in
                            Button { selected = entry.id } label: { card(entry) }.buttonStyle(.plain)
                                .accessibilityLabel("\(entry.app), \(entry.summary), \(entry.status)")
                        }
                    }
                    if !common.isEmpty {
                        DisclosureGroup("모든 앱의 공통 규칙") { Text(common).font(.callout).textSelection(.enabled).padding(.top, 8) }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onChange(of: state.ledgerVersion) { _, _ in reload() }
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() {
        let db = try? DB(path: AppSettings.dbPath)
        let books = Playbooks.all()
        common = books.first { $0.app == "공통" }?.text ?? ""
        entries = books.filter { $0.app != "공통" }.map { book in
            PlaybookEntry(app: book.app, text: book.text, footprints: FootprintStore.load(book.app),
                          installed: db.flatMap { db in (try? db.state("installed:\(book.app)")) ?? nil })
        }
    }

    private func icon(_ entry: PlaybookEntry) -> some View {
        Group {
            if let name = entry.icon, let url = Web.bundle.url(forResource: name, withExtension: "png", subdirectory: "Web/icons"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(entry.app == "여기어때" ? "여기\n어때" : String(entry.app.prefix(2)))
                    .font(.system(size: 14, weight: .heavy)).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.pink.opacity(0.8))
            }
        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }

    private func card(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon(entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.app).font(.headline)
                    Text(entry.installation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            Text(entry.summary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Label(entry.status, systemImage: entry.verified.isEmpty ? "clock" : "checkmark.circle")
                .font(.caption).foregroundStyle(entry.verified.isEmpty ? Color.secondary : Color.green)
            Text("문서 절차 \(entry.steps.count)단계 · 저장된 동작 \(entry.footprints.count)개")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.09)))
    }

    private func detail(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) { icon(entry); VStack(alignment: .leading, spacing: 4) {
                Text(entry.app).font(.title2.bold()); Text(entry.summary).foregroundStyle(.secondary)
            } }
            GroupBox("재생 검증 상태") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.status).font(.headline)
                    Text("재생 또는 반복 실행에서 확인된 동작별 기록입니다. 전체 절차의 완료를 뜻하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.verified, id: \.id) { fp in
                        Label("\(fp.glyph) \(fp.target) · 성공 \(fp.verified.ok)회 · 실패 \(fp.verified.fail)회", systemImage: "checkmark.circle")
                    }
                    if entry.verified.isEmpty { Text("아직 성공한 재생 기록이 없습니다.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("문서에 정리된 절차") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entry.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) { Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary); Text(step) }
                    }
                    if entry.steps.isEmpty { Text("단계별 절차가 아직 없습니다.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("사람이 필요한 순간") {
                Text(entry.app == "여기어때" ? "로그인·인증은 직접 진행합니다. 최종 결제는 사람의 승인 후 한 번만 시도합니다." : "로그인·인증은 직접 진행합니다. 은행 앱에서는 읽기만 하며 이체·송금은 하지 않습니다.")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("상세 사용법과 주의사항") { Text(entry.text).font(.callout).textSelection(.enabled).padding(.top, 8) }
            DisclosureGroup("개발자 명세") {
                Text(entry.footprints.map { "\($0.glyph) \($0.target)\n전: \($0.fingerprintBefore.joined(separator: ", "))\n후: \($0.fingerprintAfter.joined(separator: ", "))" }.joined(separator: "\n\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            }
        }
    }
}
