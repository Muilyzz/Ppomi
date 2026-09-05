import SwiftUI
import AppKit

/// The manifest describes intent. Runtime evidence alone describes what actually replayed.
struct PlaybookEntry: Identifiable {
    let record: PlaybookRecord
    let footprints: [Footprint]
    let installed: String?
    var id: String { record.id }
    var evidence: PlaybookEvidence { PlaybookEvidence(footprints, version: record.manifest.version) }
    func replayOK(_ footprint: Footprint) -> Int { footprint.verified.replayVersions?[record.manifest.version]?.ok ?? 0 }
    func replayFail(_ footprint: Footprint) -> Int { footprint.verified.replayVersions?[record.manifest.version]?.fail ?? 0 }
    var replayed: [Footprint] { footprints.filter { replayOK($0) > 0 } }
    var stepCount: Int { record.manifest.capabilities.reduce(0) { $0 + $1.steps.count } }
    var status: String { evidence.replayedSteps == 0 ? "현재 버전 재생 검증 전" : "현재 버전 재생 성공 \(evidence.replayedSteps)개 동작" }
    var installation: String { installed == "1" ? "설치 확인됨" : installed == "0" ? "미설치" : "설치 여부 미확인" }
}

struct PlaybooksView: View {
    @EnvironmentObject var state: AppState
    @State private var entries: [PlaybookEntry] = []
    @State private var common = ""
    @State private var selected: String?
    @State private var importError: String?
    @State private var catalogIssues: [PlaybookCatalog.Issue] = []
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
                    Button(action: importPlaybook) { Label("가져오기", systemImage: "square.and.arrow.down") }
                        .help("플레이북 폴더 가져오기")
                    Button(action: reload) { Image(systemName: "arrow.clockwise") }.help("플레이북 새로고침")
                }
                if !catalogIssues.isEmpty {
                    DisclosureGroup("불러오지 못한 플레이북 \(catalogIssues.count)개") {
                        ForEach(catalogIssues) { issue in
                            Text("\(issue.directory.lastPathComponent): \(issue.message)").font(.callout).textSelection(.enabled)
                        }
                    }.foregroundStyle(.secondary)
                }
                if let entry = entries.first(where: { $0.id == selected }) {
                    Button { selected = nil } label: { Label("모든 앱", systemImage: "chevron.left") }
                    detail(entry)
                } else {
                    if entries.isEmpty {
                        ContentUnavailableView("저장된 플레이북이 없습니다", systemImage: "books.vertical", description: Text("플레이북 폴더를 가져오면 앱과 사용법이 표시됩니다."))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(entries) { entry in
                            Button { selected = entry.id } label: { card(entry) }.buttonStyle(.plain)
                                .accessibilityLabel("\(entry.record.name), \(entry.record.summary), \(entry.status)")
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
        .alert("플레이북을 가져오지 못했습니다", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private func reload() {
        let db = try? DB(path: AppSettings.dbPath)
        common = PlaybookCatalog.common(in: Playbooks.dir)
        let catalog = PlaybookCatalog.inspect(in: Playbooks.dir, includeBundled: true)
        catalogIssues = catalog.issues
        entries = catalog.records.map { record in
            let keys = [record.id, record.name] + record.manifest.aliases
            let installed = keys.lazy.compactMap { key -> String? in
                guard let db else { return nil }
                return try? db.state("installed:\(key)")
            }.first
            return PlaybookEntry(record: record, footprints: FootprintStore.load(record.id), installed: installed)
        }
        if let selected, !entries.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    private func importPlaybook() {
        let panel = NSOpenPanel()
        panel.title = "플레이북 폴더 선택"
        panel.message = "명세와 아이콘, 사용법이 들어 있는 플레이북 폴더를 선택하세요."
        panel.prompt = "가져오기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try PlaybookCatalog.install(from: url, in: Playbooks.dir)
            reload()
            selected = imported.id
        } catch { importError = error.localizedDescription }
    }

    private func icon(_ entry: PlaybookEntry) -> some View {
        Group {
            if let url = entry.record.iconURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }

    private func card(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon(entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.record.name).font(.headline)
                    Text(entry.installation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            Text(entry.record.summary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Label(entry.status, systemImage: entry.replayed.isEmpty ? "clock" : "checkmark.circle")
                .font(.caption).foregroundStyle(entry.replayed.isEmpty ? Color.secondary : Color.green)
            Text("명세 \(entry.stepCount)단계 · 저장된 동작 \(entry.footprints.count)개")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.09)))
    }

    private func detail(_ entry: PlaybookEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) { icon(entry); VStack(alignment: .leading, spacing: 4) {
                Text(entry.record.name).font(.title2.bold())
                Text(entry.record.summary).foregroundStyle(.secondary)
                Text("버전 \(entry.record.manifest.version) · \(entry.installation)").font(.caption).foregroundStyle(.secondary)
            } }
            replayEvidence(entry)
            capabilities(entry)
            GroupBox("사람이 필요한 순간") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.record.manifest.humanSteps.enumerated()), id: \.offset) { _, step in Text(step) }
                    if entry.record.manifest.humanSteps.isEmpty { Text("명세에 별도 단계가 없습니다. 공통 승인 규칙은 항상 적용됩니다.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            DisclosureGroup("상세 사용법과 주의사항") { Text(entry.record.guideText).font(.callout).textSelection(.enabled).padding(.top, 8) }
            DisclosureGroup("개발자 명세") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Playbooks.definition(entry.record))
                    Text(entry.footprints.map { "\($0.glyph) \($0.target)\n전: \($0.fingerprintBefore.joined(separator: ", "))\n후: \($0.fingerprintAfter.joined(separator: ", "))" }.joined(separator: "\n\n"))
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            }
        }
    }

    private func replayEvidence(_ entry: PlaybookEntry) -> some View {
        GroupBox("현재 버전 재생 검증 상태") {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.status).font(.headline)
                Text("플레이북 \(entry.record.manifest.version)의 자동 재생에서 확인한 동작별 기록입니다. 전체 절차의 완료를 뜻하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                ForEach(entry.replayed, id: \.id) { footprint in
                    Label("\(footprint.glyph) \(footprint.target) · 재생 성공 \(entry.replayOK(footprint))회 · 실패 \(entry.replayFail(footprint))회", systemImage: "checkmark.circle")
                }
                if entry.replayed.isEmpty { Text("현재 버전에서 성공한 재생 기록이 없습니다.").foregroundStyle(.secondary) }
                if entry.evidence.replayFail > 0 { Text("재생 실패 \(entry.evidence.replayFail)회").font(.caption).foregroundStyle(.secondary) }
                if entry.evidence.historicalOK > 0 || entry.evidence.historicalFail > 0 {
                    Text("누적 관찰 성공 \(entry.evidence.historicalOK)회 · 실패 \(entry.evidence.historicalFail)회. 이전 기록은 재생과 수동 조작을 구분하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func capabilities(_ entry: PlaybookEntry) -> some View {
        GroupBox("할 수 있는 일") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(entry.record.manifest.capabilities, id: \.id) { capability in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(capability.title).font(.headline)
                        Text(capability.description).font(.callout).foregroundStyle(.secondary)
                        if !capability.inputs.isEmpty {
                            Text("필요한 입력").font(.subheadline.bold())
                            ForEach(capability.inputs, id: \.name) { input in
                                Text("\(input.label) · \(input.required ? "필수" : "선택")").font(.callout)
                            }
                        }
                        ForEach(Array(capability.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Text(step.title)
                            }
                        }
                    }
                }
                if entry.record.manifest.capabilities.isEmpty { Text("작업 명세가 아직 없습니다.").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
