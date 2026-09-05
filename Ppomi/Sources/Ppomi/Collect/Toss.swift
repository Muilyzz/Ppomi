// 토스증권 Open API: holdings into snapshots (total) + holdings (per symbol). No screen needed. Ported from am.py.
// Keys: tossinvest.com (WTS) 설정 > Open API → TOSSINVEST_CLIENT_ID/SECRET in .env; register this Mac's public IP (else 403).
import Foundation

enum Toss {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Holding {
        var symbol, name: String
        var country, currency: String?
        var quantity, lastPrice, avgPrice: Double
        var marketValueKRW, pnlKRW: Int
        var pnlRate: Double
    }
    static let api = "https://openapi.tossinvest.com"

    static func call(_ path: String, token: String? = nil, account: String? = nil, form: [String: String]? = nil) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: api + path)!, timeoutInterval: 30)
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let account { req.setValue(account, forHTTPHeaderField: "X-Tossinvest-Account") }
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: req) { out = ($0, $1, $2); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw Failure(description: "tossinvest \(path): \(e.localizedDescription)") }
        let code = (out.1 as? HTTPURLResponse)?.statusCode ?? 0, data = out.0 ?? Data()
        guard (200..<300).contains(code) else { throw Failure(description: "tossinvest \(path) \(code): \(String(decoding: data.prefix(200), as: UTF8.self))") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Client-credentials token, cached in the state table until a minute before it expires.
    static func token(db: DB) throws -> String? {
        guard let cid = AppSettings.env("TOSSINVEST_CLIENT_ID"), let sec = AppSettings.env("TOSSINVEST_CLIENT_SECRET"), !cid.isEmpty, !sec.isEmpty else { return nil }
        if let exp = try db.state("toss_token_exp").flatMap(Double.init), exp > Date().timeIntervalSince1970 + 60, let t = try db.state("toss_token") { return t }
        let d = try call("/oauth2/token", form: ["grant_type": "client_credentials", "client_id": cid, "client_secret": sec])
        guard let t = d["access_token"] as? String else { throw Failure(description: "tossinvest token: \(d)") }
        try db.setState("toss_token", t)
        try db.setState("toss_token_exp", "\(Date().timeIntervalSince1970 + Double((d["expires_in"] as? Int) ?? 3600))")
        return t
    }

    /// HoldingsOverview → (total market value in KRW, items, PnL rate). Amounts are strings per currency.
    static func parseHoldings(_ r: [String: Any], usdKRW: Double) -> (total: Int, items: [Holding], rate: Double?) {
        let num = { (v: Any?) -> Double in (v as? Double) ?? Double("\(v ?? "")") ?? 0 }
        let mv = (r["marketValue"] as? [String: Any])?["amount"] as? [String: Any] ?? [:]
        let total = num(mv["krw"]) + num(mv["usd"]) * usdKRW
        let items = ((r["items"] as? [[String: Any]]) ?? []).map { it -> Holding in
            let fx = (it["currency"] as? String) == "KRW" ? 1.0 : usdKRW
            let pl = it["profitLoss"] as? [String: Any] ?? [:]
            return Holding(symbol: "\(it["symbol"] ?? "")", name: "\(it["name"] ?? "")", country: it["marketCountry"] as? String, currency: it["currency"] as? String,
                           quantity: num(it["quantity"]), lastPrice: num(it["lastPrice"]), avgPrice: num(it["averagePurchasePrice"]),
                           marketValueKRW: Int((num((it["marketValue"] as? [String: Any])?["amount"]) * fx).rounded()),
                           pnlKRW: Int((num(pl["amount"]) * fx).rounded()), pnlRate: num(pl["rate"]))
        }
        let rate = (r["profitLoss"] as? [String: Any])?["rate"]
        return (Int(total.rounded()), items, rate.map(num))
    }

    /// Best effort: the API's exchange-rate endpoint; falls back to 1400 (flagged) so USD holdings still show up.
    static func usdKRW(token: String) -> (Double, Bool) {
        guard let d = try? call("/api/v1/exchange-rate", token: token) else { return (1400, false) }
        let r = d["result"] ?? d
        let keys = ["rate", "exchangeRate", "usdKrw", "price", "basePrice"]
        let pick = { (o: [String: Any]) -> Double? in keys.lazy.compactMap { k in o[k].flatMap { Double("\($0)") } }.first }
        if let o = r as? [String: Any], let v = pick(o) { return (v, true) }
        if let a = r as? [[String: Any]], let o = a.first, let v = pick(o) { return (v, true) }
        return (1400, false)
    }

    /// Collect every brokerage account. Returns rows stored.
    @discardableResult
    static func collect(db: DB, log: (String) -> Void) throws -> Int {
        guard let token = try token(db: db) else { log("TOSSINVEST: no credentials (.env TOSSINVEST_CLIENT_ID/SECRET)"); return 0 }
        let accounts = (try call("/api/v1/accounts", token: token)["result"] as? [[String: Any]]) ?? []
        let (fx, fxOK) = usdKRW(token: token)
        let ts = TS.string(Date()), shot = "api-\(ts)"
        var n = 0
        for a in accounts {
            if let t = a["accountType"] as? String, t != "BROKERAGE" { continue }
            Thread.sleep(forTimeInterval: 1.1)                    // account group: 1 request/second
            let res = (try call("/api/v1/holdings", token: token, account: "\(a["accountSeq"] ?? "")")["result"] as? [String: Any]) ?? [:]
            let (total, items, rate) = parseHoldings(res, usdKRW: fx)
            let label = "토스증권 …\("\(a["accountNo"] ?? "")".suffix(4))" + (fxOK ? "" : " (USD 환율 추정)")
            try db.insertSnapshot(ts: ts, app: "TOSSINVEST", account: label, balance: total, shot: shot)
            for it in items { try db.insertHolding(ts: ts, account: label, it) }
            n += 1 + items.count
            log("TOSSINVEST: \(label) = \(total.won), \(items.count) holdings" + (rate.map { String(format: ", 손익률 %+.1f%%", $0 * 100) } ?? ""))
        }
        return n
    }
}
