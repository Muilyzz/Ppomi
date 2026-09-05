// Card / bank alert SMS from Messages (chat.db) into transactions. Ported from am.py (parse_sms, decode_attributed_body,
// ingest_sms, watch_sms). Reading chat.db needs Full Disk Access for this binary.
import Foundation
import SQLite3

enum SMS {
    struct Parsed: Equatable {
        var ts: String, kind: String, amount: Int
        var merchant: String?, card: String?, cumulative: Int?
    }
    static let chatDB = NSHomeDirectory() + "/Library/Messages/chat.db"

    static let amountRe = Re(#"(-?)(\d[\d,]{0,14})\s*원"#)            // first char must be a digit: ', 원하시는' is not money
    static let cumRe = Re(#"(?:누적|잔액)\s*(-?)(\d[\d,]{0,14})\s*원"#)
    static let dateRe = Re(#"(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})"#)
    static let noise = Re("\\(광고\\)|수신거부|이벤트|캐시백|예정|거절|실패|한도초과")
    static let cardKinds = [("승인취소", "cancel"), ("취소", "cancel"), ("승인", "approval")]
    static let bankKinds = [("출금", "withdrawal"), ("입금", "deposit")]

    private static func money(_ m: Re.Match) -> Int { Int(m[1]! + m[2]!.replacingOccurrences(of: ",", with: ""))! }

    /// Tolerant parser for Korean card/bank alert SMS. Formats differ per issuer, so it keys off tokens
    /// (금액원, 승인/취소/입금/출금, MM/DD HH:MM) instead of full templates.
    static func parse(_ text: String, when: Date) -> Parsed? {
        if noise.search(text) != nil { return nil }
        let t = Re(#"\[[^\]]*발신\]"#).sub(text, "")
        let lines = t.components(separatedBy: CharacterSet(charactersIn: "\r\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let flat = lines.joined(separator: " "), ns = flat as NSString
        let cum = cumRe.search(flat)
        let cumStart = cum?.r.range(at: 2).location
        var amounts: [(Int, Int)] = []
        for m in amountRe.re.matches(in: flat, range: NSRange(location: 0, length: ns.length)) {
            let mm = Re.Match(s: ns, r: m)
            if m.range(at: 2).location != cumStart { amounts.append((m.range(at: 2).location, money(mm))) }
        }
        guard let first = amounts.first else { return nil }         // foreign-currency approvals (USD 12.34) land here on purpose
        // kind: decided from the header up to the transaction amount, bank vs card vocab (a bank deposit whose memo says
        // '신한카드취소' must stay a deposit; '출금계좌 1234' in a deposit memo must not flip it to withdrawal)
        var scope = ns.substring(to: first.0); if scope.isEmpty { scope = flat }
        let kinds = Re("은행|뱅크").search(lines[0]) != nil ? bankKinds : cardKinds
        guard let kind = kinds.first(where: { scope.contains($0.0) })?.1 ?? kinds.first(where: { flat.contains($0.0) })?.1 else { return nil }
        var ts = TS.string(when)
        let m = dateRe.search(flat)
        if let m {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: when)
            let mo = Int(m[1]!)!, d = Int(m[2]!)!, h = Int(m[3]!)!, mi = Int(m[4]!)!
            let y = c.year! - ((mo, d) > (c.month!, c.day!) ? 1 : 0)   // 12/31 alert read on 01/01
            ts = String(format: "%04d-%02d-%02d %02d:%02d", y, mo, d, h, mi)
        }
        let card = Re("([가-힣A-Za-z]{1,6}카드)").search(flat)?[1]
        let last4 = Re(#"\((\d{4})\)|(\d\*\d\*)"#).search(flat)
        var merchant: String?
        for l in lines.dropFirst() {                                 // line 0 is the issuer header
            if amountRe.search(l) != nil || dateRe.search(l) != nil || l.contains("*") { continue }   // money, time, masked customer name
            if Re(#"승인|취소|입금|출금|누적|잔액|일시불|\d+개월|^USD|^JPY|^EUR"#).search(l) != nil
                || Re(#"^[가-힣A-Za-z]{1,6}카드(\(\d{4}\))?$"#).match(l) != nil { continue }   // keywords, or a bare card name line
            merchant = l; break
        }
        if merchant == nil, let m {                                  // single-line formats: merchant follows the time
            var tail = ns.substring(from: m.r.range.location + m.r.range.length)
            tail = Re("누적|잔액").re.matches(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)).first.map { (tail as NSString).substring(to: $0.range.location) } ?? tail
            tail = Re(#"-?\d[\d,]*\s*원|\(?일시불\)?|\d+개월|\([^)]*\)"#).sub(tail, " ")
            let s = tail.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            merchant = s.isEmpty ? nil : s
        }
        let cardText = card.map { $0 + (last4.map { "(\($0[1] ?? $0[2] ?? ""))" } ?? "") }
        return Parsed(ts: ts, kind: kind, amount: first.1, merchant: merchant, card: cardText, cumulative: cum.map(money))
    }

    /// macOS 13+ stores message text in a typedstream blob when `text` is NULL.
    static func decodeAttributedBody(_ blob: Data) -> String? {
        guard let r = blob.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound + 5                                     // skip \x01\x94\x84\x01\x2b
        guard i < blob.count else { return nil }
        var n = Int(blob[i])
        if n == 0x81 { guard i + 3 <= blob.count else { return nil }; n = Int(blob[i + 1]) | Int(blob[i + 2]) << 8; i += 3 }
        else if n == 0x82 { guard i + 5 <= blob.count else { return nil }; n = Int(blob[i + 1]) | Int(blob[i + 2]) << 8 | Int(blob[i + 3]) << 16 | Int(blob[i + 4]) << 24; i += 5 }
        else { i += 1 }
        return String(decoding: blob[i..<min(blob.count, i + n)], as: UTF8.self)
    }

    /// Pull new SMS from Messages into transactions. The newly inserted rows, or nil when chat.db is unreadable (no Full Disk Access).
    static func ingest(db: DB) -> [Parsed]? {
        let last = Int((try? db.state("sms_rowid")) ?? "0") ?? 0
        var src: OpaquePointer?
        guard sqlite3_open_v2("file:\(chatDB)?mode=ro", &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let src else { return nil }
        defer { sqlite3_close(src) }
        var stmt: OpaquePointer?
        let sql = """
            SELECT m.ROWID, m.date/1000000000 + 978307200, m.text, m.attributedBody, h.id
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ? AND m.is_from_me = 0 ORDER BY m.ROWID
            """
        guard sqlite3_prepare_v2(src, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(last))
        var new: [Parsed] = [], lastRow: Int? = nil
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0)); lastRow = rowid
            let epoch = sqlite3_column_double(stmt, 1)
            let sender = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            if sender.contains("@") { continue }                     // iMessage from a person, not an SMS short code
            var text = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            if text == nil, let p = sqlite3_column_blob(stmt, 3) { text = decodeAttributedBody(Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 3)))) }
            guard let text, !text.isEmpty, let p = parse(text, when: Date(timeIntervalSince1970: epoch)) else { continue }
            let n = (try? db.exec("INSERT OR IGNORE INTO transactions(ts,kind,amount,merchant,card,cumulative,source,msg_rowid,raw) VALUES(?,?,?,?,?,?,?,?,?)",
                                  [p.ts, p.kind, p.amount, p.merchant, p.card, p.cumulative, "sms:\(sender)", rowid, text])) ?? 0
            if n > 0 { new.append(p) }
        }
        if let lastRow { try? db.setState("sms_rowid", "\(lastRow)") }
        return new
    }

    /// serve tick: if Messages' database changed since last tick, ingest and announce new card events (~30s latency).
    static func watch(db: DB, todayLine: () -> String) {
        guard let m = try? FileManager.default.attributesOfItem(atPath: chatDB)[.modificationDate] as? Date else { return }
        let mtime = "\(m.timeIntervalSince1970)"
        if mtime == ((try? db.state("sms_mtime")) ?? nil) { return }
        try? db.setState("sms_mtime", mtime)
        guard let new = ingest(db: db) else {
            if ((try? db.state("sms_warned")) ?? nil) == nil {
                try? db.setState("sms_warned", "1")
                Notify.post("문자 수집 비활성", "전체 디스크 접근 권한을 켜면 카드 문자를 실시간 수집합니다")
            }
            return
        }
        for p in new where p.kind == "approval" || p.kind == "cancel" {
            let sign = p.kind == "cancel" ? "-" : ""
            Notify.post(p.kind == "approval" ? "💳 결제" : "↩︎ 취소", "\(HTML.esc(p.merchant ?? "")) <b>\(sign)\(p.amount.won)</b> · " + todayLine())
        }
    }
}
