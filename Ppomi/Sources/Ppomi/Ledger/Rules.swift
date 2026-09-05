// The accounting rules, ported line for line from report.py (ACCOUNT, CAPITAL, capital, journal, classify, chain_order,
// norm_label). Regexes keep Python re.search semantics; only capital() is case-insensitive (re.I), as in the source.
import Foundation

enum Rules {
    /// The account each app's transaction list belongs to: (regex over snapshot labels, the journal's own name for it).
    static let account: [String: (pattern: String, name: String)] = [
        "KAKAO": ("AI 관련 지출", "카카오뱅크 AI 관련 지출 통장"),
        "KB": ("ONE통장", "KB국민ONE통장"),
    ]
    /// What the won turned into (debit side of a spend); first match wins, default 유지.
    static let capitals: [(pattern: String, capital: String)] = [
        ("CURSOR|AWS|VERCEL|Google|GROK|APPLE|Amazon|OPENAI|ANTHROPIC", "역량"), ("쿠팡이츠|배달|택시|카카오 ?T", "시간"),
        ("사우나|헬스|병원|약국", "건강"), ("축의|조의|부의|경조", "관계"), ("유튜브|넷플릭스|멜론|게임", "즐거움"),
    ]
    /// Capitals and outside sources: no lens contains them.
    static let neverInside: Set<String> = Set(["이자수입", "수입(미분류)", "유지"] + capitals.map(\.capital))
    /// am.title(app): the app's Korean name.
    static let titles = ["KB": "KB스타뱅킹", "KAKAO": "카카오뱅크", "KBANK": "케이뱅크", "TOSS": "토스", "TOSSINVEST": "토스증권(API)"]
    static func title(_ app: String) -> String { titles[app] ?? app }

    static func capital(of merchant: String) -> String { capitalsCI.first { search($0.0, merchant) }?.1 ?? "유지" }

    /// OCR noise '1 AI 관련 지출 통장', masked / last-4 account numbers, whitespace runs.
    static func normLabel(_ label: String) -> String {
        let a = leadingDigits.stringByReplacingMatches(in: label, range: NSRange(label.startIndex..., in: label), withTemplate: "")
        let b = maskedNumber.stringByReplacingMatches(in: a, range: NSRange(a.startIndex..., in: a), withTemplate: "")
        return b.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The chain in true order. Rows sharing a minute come out of the app newest-first, so their ids run backwards; within
    /// such a group take the permutation whose balances follow from the previous one, else leave the group as is.
    static func chainOrder(_ rows: [Transaction]) -> [Transaction] {
        func signed(_ r: Transaction) -> Int { r.kind == .deposit || r.kind == .cancel ? r.amount : -r.amount }
        func closes(_ p: [Transaction], from bal: Int) -> Bool {
            var b = bal
            for r in p { guard let c = r.cumulative, c == b + signed(r) else { return false }; b = c }
            return true
        }
        var out: [Transaction] = [], bal: Int? = nil, i = 0
        while i < rows.count {
            var j = i
            while j < rows.count, rows[j].ts == rows[i].ts { j += 1 }
            var g = Array(rows[i..<j])
            if let b = bal, g.count > 1 { g = permutations(g).first { closes($0, from: b) } ?? g }
            out += g; bal = g.last?.cumulative; i = j
        }
        return out
    }

    /// Double-entry lines from transaction rows. A line names both ends as concretely as the data allows and nothing else;
    /// what it is (transfer, income, spend) is decided at read time by classify(). Accounts are named the journal's way
    /// (account[app].name); Ledger.load maps them to balance-sheet labels. `me`: deposits carrying the own name are transfers.
    static func journal(_ rows: [Transaction], me: String) -> [JournalLine] {
        var out: [JournalLine] = []
        for r in rows {
            let acct = account[r.app]?.name ?? r.app          // Python raises on an unknown app; here it names itself
            let m = r.merchant, tag = r.tag
            let own = !me.isEmpty && has(m, me)
            var k = 0
            func add(_ memo: String, dr: String, cr: String, rev: Bool = false, inferred: Bool = false) {
                out.append(JournalLine(id: "\(r.uid)#\(k)", ts: r.ts, memo: memo, dr: dr, cr: cr, amount: r.amount, rev: rev, inferred: inferred, uid: r.uid))
                k += 1
            }
            switch r.kind {
            case .deposit:
                if has(tag, "체크카드") { add("\(tag) \(m) 환불", dr: acct, cr: capital(of: m), rev: true) }   // a card refund shows as an unsigned deposit tagged 체크카드
                else if has(m, "ATM입금") { add("\(tag) \(m)", dr: acct, cr: "현금(수중)") }
                else if has(tag, "이자") || has(m, "이자") { add("\(tag) \(m)", dr: acct, cr: "이자수입") }
                else if own { add("\(tag) \(m)", dr: acct, cr: "내 다른 계좌(미확인)") }
                else { add("\(tag) \(m)", dr: acct, cr: "수입(미분류)") }
            case .withdrawal:
                if has(tag, "스마트출금") || has(tag, "ATM") || own {
                    add("\(tag) \(m)", dr: "현금(수중)", cr: acct)
                    if let cap = capitalsCS.first(where: { search($0.0, m) })?.1 {        // the memo says what the cash was for: a second, inferred line
                        add("↳ \(m) (메모에서 추정)", dr: cap, cr: "현금(수중)", inferred: true)
                    }
                } else { add("\(tag) \(m)", dr: capital(of: m), cr: acct) }
            case .approval: add("\(tag) \(m)", dr: capital(of: m), cr: acct)
            case .cancel: add("\(tag) \(m) 취소", dr: acct, cr: capital(of: m), rev: true)
            }
        }
        return out
    }

    /// What a line is under a boundary: both ends inside = transfer; money leaving = conversion (spend); money arriving =
    /// income, or a reversal when it is a refund; neither end inside = none.
    static func classify(_ l: JournalLine, inside: Set<String>) -> Flow {
        let d = inside.contains(l.dr), c = inside.contains(l.cr)
        return d && c ? .transfer : c ? .conversion : d ? (l.rev ? .reversal : .income) : .none
    }

    /// Python `sub in s`: code-point substring. String.contains would also match canonically equivalent (NFD) text.
    static func has(_ s: String, _ sub: String) -> Bool { s.range(of: sub, options: .literal) != nil }

    /// re.search: does the pattern occur anywhere in s.
    static func search(_ pattern: String, _ s: String) -> Bool { (try? NSRegularExpression(pattern: pattern)).map { search($0, s) } ?? false }

    // MARK: - regex plumbing
    private static func re(_ p: String, ci: Bool = false) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : []) }
    private static func search(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    private static let capitalsCI = capitals.map { (re($0.pattern, ci: true), $0.capital) }   // capital(): re.I
    private static let capitalsCS = capitals.map { (re($0.pattern), $0.capital) }             // the inferred cash line: case-sensitive
    private static let leadingDigits = re(#"^\d+\s+"#), maskedNumber = re(#"\s*\(\*+\)|\s*…\d{4}"#)

    /// itertools.permutations order (by position), so the first closing permutation is the one Python picks.
    /// ponytail: n! eager; a minute holds a handful of rows, never enough to matter.
    private static func permutations<T>(_ a: [T]) -> [[T]] {
        if a.count <= 1 { return [a] }
        return a.indices.flatMap { i -> [[T]] in var rest = a; let x = rest.remove(at: i); return permutations(rest).map { [x] + $0 } }
    }
}
