// `--mcp`: the phone, the ledger and the one approval gate as MCP tools (stdio, JSON-RPC 2.0, one JSON object per line),
// so an outside agent (Claude app, Claude Code) can be the brain. The protocol goes to `fd`; every log line goes to stderr.
// Approval never comes through a tool argument: confirm_payment / ask_choice reach a person, by elicitation when the client
// supports it, else through the 뽀미 window's buttons (Tools.askViaDB).
import Foundation

final class MCPServer {
    private let db: DB, ro: DB                     // ro: the read-only handle the sql tool uses (WITH … DELETE would pass a prefix check)
    private let tools: Tools
    private let out: FileHandle
    private let lock = NSLock()                    // one writer at a time; also guards `pending` and `nextID`
    private let calls = DispatchQueue(label: "ppomi.mcp.tools")   // the phone does one thing at a time; the read loop stays free
    private var pending: [String: (Any?) -> Void] = [:]          // our request id → the client's reply
    private var nextID = 0
    private var elicitation = false

    init(dbPath: String, fd: Int32 = 1) throws {
        db = try DB(path: dbPath, writable: true)
        ro = try DB(path: dbPath)
        tools = try Tools(db: db)
        out = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        tools.askOwner = { [unowned self] html, options in self.ask(html, options) }
    }

    /// Reads stdin until EOF, each line one message; then lets the tool call in flight finish (its answer still goes out).
    func run() {
        signal(SIGPIPE, SIG_IGN)                      // client gone: the write fails, the tool in flight still finishes
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let m = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]); continue
            }
            handle(m)
        }
        lock.lock(); let waiting = pending.values; pending = [:]; lock.unlock()
        waiting.forEach { $0(nil) }                   // nobody left to answer an elicitation: 무응답, not a 5-minute wait
        calls.sync {}
    }

    // ---------------------------------------------------------------- messages
    private func handle(_ m: [String: Any]) {
        let id = m["id"]
        guard let method = m["method"] as? String else {                      // no method: the client's reply to one of ours
            guard let id else { return }
            lock.lock(); let h = pending.removeValue(forKey: "\(id)"); lock.unlock()
            h?(m["result"])
            return
        }
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let v = params["protocolVersion"] as? String ?? ""
            elicitation = (params["capabilities"] as? [String: Any])?["elicitation"] != nil
            reply(id, ["protocolVersion": ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(v) ? v : "2025-06-18",
                       "capabilities": ["tools": [:]], "serverInfo": ["name": "ppomi", "version": "0.1"], "instructions": instructions])
            fputs("mcp: ready, elicitation=\(elicitation ? "yes" : "no")\n", stderr)
        case "notifications/initialized": break
        case "ping": reply(id, [:])
        case "tools/list": reply(id, ["tools": Self.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": ($0.json["function"] as! [String: Any])["parameters"]!] }])
        case "tools/call":
            calls.async { [self] in
                let name = params["name"] as? String ?? "", t0 = Date()
                let r = call(name, params["arguments"] as? [String: Any] ?? [:])
                Telemetry.record("tool", ["name": name, "ok": r["isError"] == nil, "ms": Int(Date().timeIntervalSince(t0) * 1000)], db: db)
                reply(id, r)
            }
        default:
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"]]) }
        }
    }

    private func reply(_ id: Any?, _ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }   // no id = notification

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes) else { return }
        d.append(10)
        lock.lock(); defer { lock.unlock() }
        try? out.write(contentsOf: d)
    }

    /// A request to the client; its result, or nil after `timeout` / an error reply.
    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 300) -> Any? {
        let sem = DispatchSemaphore(value: 0)
        var result: Any?
        lock.lock(); nextID += 1; let id = nextID; pending["\(id)"] = { result = $0; sem.signal() }; lock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if sem.wait(timeout: .now() + timeout) == .timedOut { lock.lock(); pending["\(id)"] = nil; lock.unlock() }
        return result
    }

    /// The owner's answer to a question with buttons: an elicitation, or the 뽀미 window. Only a person answers; nil = 취소/무응답.
    private func ask(_ html: String, _ options: [String]) -> String? {
        guard elicitation else { return Tools.askViaDB(db, html, options) }
        let schema: [String: Any] = ["type": "object", "required": ["choice"],
                                     "properties": ["choice": ["type": "string", "title": "선택", "enum": options, "enumNames": options]]]
        let r = request("elicitation/create", ["message": HTML.plain(html), "requestedSchema": schema]) as? [String: Any]
        guard r?["action"] as? String == "accept", let c = (r?["content"] as? [String: Any])?["choice"] as? String, options.contains(c) else { return nil }
        return c
    }

    // ---------------------------------------------------------------- tools
    private static let reused = ["phone_screen", "phone_tap", "phone_type", "phone_key", "phone_scroll", "phone_open", "phone_installed", "run_combo",
                                 "pay_preference", "confirm_payment", "record_spend", "balances", "today_spending", "ask_choice"]
    static let tools: [ToolSpec] = reused.compactMap { n in Tools.specs.first { $0.name == n } } + [
        Tools.T("transactions", "최근 days 일의 거래(ts, amount, merchant, card, kind, uid, status) JSON 배열, 최신순 최대 300행.", ["days": ("integer", "기본 30")]),
        Tools.T("sql", "장부(SQLite)에 읽기 전용 SQL. SELECT/WITH 만. 결과 {columns, rows}, 200행 상한. 테이블: transactions, snapshots, holdings, state, later, facts.",
                ["query": ("string", nil)], ["query"]),
        Tools.T("read_playbook", "앱별 절차(콤보와 버릇). 폰 앱 작업 전에 읽어라. app 을 비우면 전부.", ["app": ("string", "앱 이름")]),
        Tools.T("note_footprint", "실행 중 새로 알게 된 앱의 버릇 한 줄. 금액·이름·예약번호 같은 개인정보 금지. glyph 를 주면 마지막으로 읽은 화면의 걸음으로도 남긴다(run_combo 가 그 화면에서 멈춰 두뇌에 넘긴다).",
                ["app": ("string", nil), "line": ("string", nil), "glyph": ("string", "선택: 이 화면의 걸음 기호(⊙ ⌨ ↓ ⎋ 👤 🎟 🔍 ✋ 📝)"), "target": ("string", "선택: 탭할 글자 정규식·입력할 글자")], ["app", "line"]),
    ]

    private var instructions: String {
        (Playbooks.all().first { $0.app == "공통" }?.text ?? "") +
            "\n폰 앱 작업 전에 read_playbook(앱) 을 읽고, 새 버릇은 note_footprint 로 남겨라. 결제·구매 버튼은 confirm_payment 승인 뒤에만 phone_tap 된다(코드가 막는다)." +
            "\n폰 앱 작업은 run_combo 먼저, 멈춘 화면부터 phone_screen/phone_tap."
    }

    private func call(_ name: String, _ a: [String: Any]) -> [String: Any] {
        fputs("tool: \(name)\n", stderr)
        func text(_ s: String, error: Bool = false) -> [String: Any] {
            var r: [String: Any] = ["content": [["type": "text", "text": s]]]; if error { r["isError"] = true }; return r
        }
        func json(_ o: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "" }
        func shot(_ t: String, _ png: URL?) -> [String: Any] {          // the text and, when there is one, the screen it came from
            guard let png, let data = try? Data(contentsOf: png) else { return text(t) }
            return ["content": [["type": "text", "text": t + "\n이미지도 같이 왔다. 좌표는 0~1 정규화."],
                                ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]]]
        }
        let str = { (k: String) in (a[k] as? String) ?? "" }
        tools.currentText = "해줘"          // the host's tool permission is the consent; phone-state refusals still come from Tools
        switch name {
        case "phone_screen":
            let (t, png) = tools.screenForMCP(); return shot(t, png)
        case "run_combo":
            return shot(tools.execute(name, a), tools.lastPNG)
        case "transactions":
            let since = KST.ymd(KST.day(KST.today, -(a["days"] as? Int ?? 30)))
            do {
                let t = try ro.table("SELECT ts, amount, merchant, card, kind, uid, status FROM transactions WHERE ts >= ? ORDER BY ts DESC", [since], limit: 300)
                return text(json(t.rows.map { r in Dictionary(uniqueKeysWithValues: zip(t.cols, r.map { $0 ?? NSNull() })) }))
            } catch { return text("sql error: \(error)", error: true) }
        case "sql":
            guard Re(#"^\s*(?i:SELECT|WITH)\b[^;]*;?\s*$"#).match(str("query")) != nil else { return text("read-only: one SELECT/WITH statement only", error: true) }
            do { let t = try ro.table(str("query"), limit: 200); return text(json(["columns": t.cols, "rows": t.rows.map { $0.map { $0 ?? NSNull() } }])) }
            catch { return text("sql error: \(error)", error: true) }
        case "read_playbook":
            let ps = Playbooks.all().filter { str("app").isEmpty || $0.app == str("app") }
            let fps = (str("app").isEmpty ? ps.map(\.app) : [str("app")]).flatMap { FootprintStore.load($0, in: tools.footprintDir) }
            return text((ps.isEmpty ? "절차 없음: \(str("app"))" : ps.map { "## \($0.app)\n\($0.text)" }.joined(separator: "\n"))
                        + "\n구조화 발자국 \(fps.count)개(검증 ok 합계 \(fps.map(\.verified.ok).reduce(0, +)))")
        case "note_footprint":
            guard !str("app").isEmpty, !str("line").isEmpty else { return text("app 과 line 이 필요하다.", error: true) }
            do { try Playbooks.append(str("app"), str("line")) } catch { return text("못 적었다: \(error)", error: true) }
            if !str("glyph").isEmpty {                                    // a structured step too, keyed on the last screen the brain read
                let fp = Footprint(app: str("app"), glyph: str("glyph"), target: str("target"), fingerprintBefore: Fingerprint.words(from: tools.lastWords), fingerprintAfter: [], note: str("line"), source: "manual")
                try? FootprintStore.append(str("app"), fp, in: tools.footprintDir)
            }
            return text("절차에 적었다: \(str("app"))")
        default:
            guard Self.reused.contains(name) else { return text("unknown tool \(name)", error: true) }
            return text(tools.execute(name, a))
        }
    }
}
