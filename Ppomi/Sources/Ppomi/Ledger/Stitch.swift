// Frames of an app's transaction list → one registered column. Ported from report.py (anchor, load_frames, stitch);
// Tests/stitch-parity.json holds what the Python said over data/shots. Pure: file in, offsets out; the page draws.
import Foundation

enum Stitch {
    /// One OCR frame of a transaction list, with the transactions parsed from its scrolling run.
    struct Frame {
        let png: URL
        let when: Date
        let rows: [String]
        let words: [[OCR.Word]]          // per row, sorted by x
        let ys: [(Double, Double)]       // per row: (top, bottom)
        var tx: [OCR.Tx] = []            // rows remapped to this frame; a pair straddling frames is boxed nowhere
        var run = 0
        var keys: [String: Int] = [:]    // anchor → row index, for anchors that appear once in this frame
    }

    /// A frame on the column: `top` is its offset in frame heights; clip/bottom cut its own sticky header and floating footer.
    struct Placed {
        let frame: Int                   // index into the frames it was built from
        let top, clip, bottom: Double
    }

    /// The floating action bar at the foot of a list: nothing below it is evidence.
    static let bottom = Re("가져오기|이체하기|^홈 메뉴")

    /// Registration key of a row, or nil: the timestamped list rows (time + balance after, or KB's date-time), reduced
    /// to their digits so OCR drift in the text between runs ('# 체크카드' vs '#체크카드') still matches.
    static func anchor(_ r: String) -> String? {
        if let m = OCR.txMeta.match(r) { return "\(m[1]!):\(m[2]!)|\(m[4]!)" }
        if let m = OCR.kbTx.match(r) { return (1...5).map { m[$0] ?? "" }.joined(separator: "|") }
        return nil
    }

    /// Frames of this app's transaction list, each with its rows, row extents and the transactions parsed from it.
    /// Frames are parsed per scrolling run (consecutive frames under 2 minutes apart, pages joined with OCR.page) exactly
    /// as the collector does, so a row whose date header sits on an earlier frame still gets its date.
    static func loadFrames(app: String, shots: URL) -> [Frame] {
        let marker = OCR.listMarkers[app]!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var out: [Frame] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for j in files {
            let groups = OCR.rowGroups(OCR.words(jsonl: j)).map { g in g.words.enumerated().sorted { ($0.1.x, $0.0) < ($1.1.x, $1.0) }.map(\.1) }
            let rows = groups.map { $0.map(\.text).joined(separator: " ") }
            guard rows.filter({ marker.match($0) != nil }).count >= 2,
                  let when = f.date(from: String(j.lastPathComponent.prefix(15))) else { continue }   // not this app's list
            out.append(Frame(png: j.deletingPathExtension().appendingPathExtension("png"), when: when, rows: rows, words: groups,
                             ys: groups.map { ws in (ws.map(\.y).min()!, ws.map { $0.y + $0.h }.max()!) }))
        }
        var run: [Int] = [], runNo = 0
        for i in 0...out.count {
            if !run.isEmpty, i == out.count || out[i].when.timeIntervalSince(out[run.last!].when) > 120 {
                var pages: [String] = [], starts: [Int] = []
                for k in run { out[k].run = runNo; starts.append(pages.count + 1); pages += [OCR.page] + out[k].rows }
                for t in OCR.parse(app: app, rows: pages, when: out[run.last!].when) {
                    let k = starts.indices.filter { starts[$0] <= t.rows.lowerBound }.max()!
                    let a = t.rows.lowerBound - starts[k], b = t.rows.upperBound - starts[k]
                    if b < out[run[k]].rows.count {          // both rows on the same frame
                        var t = t; t.rows = a...b; out[run[k]].tx.append(t)
                    }
                }
                run = []; runNo += 1
            }
            if i < out.count { run.append(i) }
        }
        return out
    }

    /// Place frames on one vertical canvas. A frame's offset = median(y_a - y_b) over the anchor rows it shares with an
    /// already placed frame; keys are time + balance-after, unique enough that one shared row suffices (more agreeing rows
    /// win). Frames are placed in order of overlap strength, not capture time, so a run that started deep in the list still
    /// lands on the run that covers the top. No overlap at all: a new segment below. Same offset as a placed frame (scroll
    /// did not move): dropped. clip/bottom: the frame's own sticky header and floating footer are not evidence.
    static func place(_ frames: inout [Frame], app: String) -> [Placed] {
        for i in frames.indices {
            let ks = frames[i].rows.map(anchor)
            var keys: [String: Int] = [:]
            for (j, k) in ks.enumerated() { if let k, ks.filter({ $0 == k }).count == 1 { keys[k] = j } }
            frames[i].keys = keys
        }
        var placed: [Placed] = [], todo = Array(frames.indices)
        func fit(_ fi: Int) -> (n: Int, top: Double) {
            var best = (0, 0.0)
            for p in placed {
                let pf = frames[p.frame], f = frames[fi]
                let shared = f.keys.compactMap { k, i in pf.keys[k].map { ($0, i) } }
                if shared.isEmpty { continue }
                let ds = shared.map { pf.ys[$0.0].0 - f.ys[$0.1].0 }.sorted()
                let d = ds[ds.count / 2], n = ds.filter { abs($0 - d) < 0.01 }.count
                if n > best.0 { best = (n, p.top + d) }
            }
            return best
        }
        while !todo.isEmpty {
            var pick = 0, fitted = (n: 0, top: 0.0)
            if !placed.isEmpty {                                     // first maximal, like Python's max()
                for (i, fi) in todo.enumerated() { let c = fit(fi); if i == 0 || c.n > fitted.n { pick = i; fitted = c } }
            }
            let fi = todo.remove(at: pick), f = frames[fi]
            var top = fitted.top
            if fitted.n >= 1 {
                if placed.contains(where: { abs(top - $0.top) < 0.02 }) { continue }
            } else {
                top = placed.map(\.top).max().map { $0 + 1.05 } ?? 0.0
            }
            // the seam goes above the first COMPLETE transaction in this frame: a frame often opens with the second line of a
            // transaction whose first line sits under the app's sticky header; that line registers the frame but is not evidence.
            let txTops = f.tx.map { f.ys[$0.rows.lowerBound].0 }
            let first = (txTops.isEmpty ? f.keys.values.map { f.ys[$0].0 } : txTops).min() ?? 0
            let clip = first - (first - 0.035 >= 0.15 ? 0.035 : 0.012)        // take its date line too, never the nav bar above 0.15
            let foot = f.rows.indices.filter { bottom.search(f.rows[$0]) != nil && f.ys[$0].0 > 0.5 }.map { f.ys[$0].0 }.min() ?? 1.0
            let last = (f.tx.map { f.ys[$0.rows.upperBound].1 } + f.keys.values.map { f.ys[$0].1 }).max() ?? 0.85
            let cap = app == "KAKAO" ? 0.88 : 0.97                            // 카카오's floating 가져오기/이체하기 bar even when OCR misses it
            placed.append(Placed(frame: fi, top: top, clip: clip, bottom: min(foot - 0.005, last + 0.05, cap)))
        }
        return placed
    }
}
