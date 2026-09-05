// A trace of the hands' work: one JSON line per event in telemetry.jsonl next to the ledger, always; the same line POSTed
// to PPOMI_TELEMETRY_URL (default: the hub's /api/telemetry) only while the owner keeps "telemetry:on" on in Settings. Names and numbers only — `keys` is the
// contract: amounts, counterparties, typed text and screen contents never get in, whatever a caller passes.
import Foundation

enum Telemetry {
    /// The only fields that may be recorded; everything else is dropped before the line exists.
    static let keys: Set<String> = ["name", "tool", "ok", "ms", "app", "step", "reason"]

    static func record(_ event: String, _ fields: [String: Any], db: DB) {
        let safe = fields.filter { keys.contains($0.key) && plain($0.value) }
        let line: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "event": event, "fields": safe]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) else { return }
        data.append(10)
        if let dbPath = (try? db.scalar("SELECT file FROM pragma_database_list WHERE name='main'")) as? String, !dbPath.isEmpty {
            let path = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("telemetry.jsonl").path
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)          // O_APPEND: whole lines even with two writers
            if fd >= 0 { data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }; close(fd) }
        }
        guard (try? db.state("telemetry:on")) == "1", let url = URL(string: AppSettings.env("PPOMI_TELEMETRY_URL") ?? "https://ppomi.vercel.app/api/telemetry") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()                         // fire and forget: a failure changes nothing here
    }

    /// A name or a number: a short single-line string, a Bool, an Int or a Double. Never something that could carry content.
    private static func plain(_ v: Any) -> Bool {
        if let s = v as? String { return s.count <= 40 && !s.contains("\n") }
        return v is Bool || v is Int || v is Double
    }
}
