// The mirrored iPhone as the collector sees it: the `phone` CLI (phone.swift next to data/) does the window, capture, OCR,
// tap, key and type; this file calls it and keeps the frames. Ported from am.py (phone, screen, find, tap).
import Foundation

enum Phone {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Repo root: data/ledger.db → ../ . The CLI and its source live there.
    static var root: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().deletingLastPathComponent() }
    static var shots: URL { URL(fileURLWithPath: AppSettings.dbPath).deletingLastPathComponent().appendingPathComponent("shots") }

    /// Run `phone args…`; stdout. The packaged app carries `phone` next to its executable (scripts/make-app.sh); otherwise the
    /// repo's binary, rebuilt when phone.swift is newer, like am.py does.
    @discardableResult
    static func run(_ args: [String], check: Bool = true) throws -> String {
        var bin = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent().appendingPathComponent("phone")
        if !FileManager.default.fileExists(atPath: bin.path) {
            bin = root.appendingPathComponent("phone"); let src = root.appendingPathComponent("phone.swift")
            let m = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
            if !FileManager.default.fileExists(atPath: bin.path) || m(bin) < m(src) {
                _ = try process("/usr/bin/swiftc", ["-O", src.path, "-o", bin.path])
            }
        }
        let (out, err, code) = try process(bin.path, args)
        if check, code != 0 { throw Failure(description: "phone \(args.first ?? ""): \(err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return out
    }

    private static func process(_ path: String, _ args: [String]) throws -> (String, String, Int32) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        try p.run()
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (out, err, p.terminationStatus)
    }

    /// Capture the mirroring window and OCR it. The PNG is kept a week for debugging, the OCR (.jsonl) for good: a better
    /// parser can rerun old runs (see am.py reparse / Stitch.loadFrames).
    static func screen() throws -> (png: URL, words: [OCR.Word]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: shots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "png" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < Date(timeIntervalSinceNow: -7 * 86400) {
                try? fm.removeItem(at: f)
            }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let png = shots.appendingPathComponent(f.string(from: Date()) + ".png")
        try run(["capture", png.path])
        let ocr = try run(["ocr", png.path])
        try ocr.write(to: png.deletingPathExtension().appendingPathExtension("jsonl"), atomically: true, encoding: .utf8)
        let dec = JSONDecoder()
        return (png, ocr.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(OCR.Word.self, from: Data($0.utf8)) })
    }

    /// Mirroring pauses when idle ('연결이 일시 정지됨' → 재개) or drops ('연결이 중단됨' → 다시 시도): click through, a few times.
    /// Bounded, for the conversation tools; the collector has its own patient loop.
    @discardableResult
    static func wake(tries: Int = 6) throws -> [OCR.Word] {
        var words: [OCR.Word] = []
        for _ in 0..<tries {
            words = try screen().words
            if let b = find(words, #"^(다시 시도|재개)$"#) { try tap(b) }                       // click through
            else if !words.isEmpty, find(words, #"^(연결이 (중단됨|일시 정지됨)|iPhone(을| ).*(사용 중|잠금 해제).*)$"#) == nil { return words }
            sleep(4)                                                                          // grey 'connecting' frame: wait
        }
        return words
    }

    // ---------------------------------------------------------------- typing
    // The mirror forwards key codes, so Hangul is typed as the 두벌식 keys that compose it ("여기어때" → "durldjEo").
    private static let cho = ["r","R","s","e","E","f","a","q","Q","t","T","d","w","W","c","z","x","v","g"]
    private static let jung = ["k","o","i","O","j","p","u","P","h","hk","ho","hl","y","n","nj","np","nl","b","m","ml","l"]
    private static let jong = ["","r","R","rt","s","sw","sg","e","f","fr","fa","fq","ft","fx","fv","fg","a","q","qt","t","T","d","w","c","z","x","v","g"]

    /// 두벌식 key letters for one Hangul syllable; nil for anything else.
    static func keys(forSyllable c: Character) -> String? {
        guard let u = c.unicodeScalars.first?.value, u >= 0xAC00, u <= 0xD7A3 else { return nil }
        let i = Int(u - 0xAC00)
        return cho[i / 588] + jung[(i % 588) / 28] + jong[i % 28]
    }
    static func keys(for text: String) -> String { text.map { keys(forSyllable: $0) ?? String($0) }.joined() }

    /// Type any text: Hangul runs through the Korean input source as 두벌식 keys, the rest as ASCII.
    static func type(_ text: String) throws {
        var run = "", korean = false
        func flush() throws { if !run.isEmpty { try Phone.run([korean ? "typeko" : "type", run]); run = "" } }
        for ch in text {
            let isKo = keys(forSyllable: ch) != nil
            if isKo != korean { try flush(); korean = isKo }
            run += isKo ? keys(forSyllable: ch)! : String(ch)
        }
        try flush()
    }

    static func find(_ words: [OCR.Word], _ pattern: String) -> OCR.Word? {
        let re = Re(pattern)
        return words.first { re.search($0.text) != nil }
    }
    static func tap(_ w: OCR.Word) throws { try tap(w.x + w.w / 2, w.y + w.h / 2) }
    static func tap(_ x: Double, _ y: Double) throws { try run(["tap", "\(x)", "\(y)"]) }
    static func key(_ name: String, check: Bool = true) throws { try run(["key", name], check: check) }
    static func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }
}
