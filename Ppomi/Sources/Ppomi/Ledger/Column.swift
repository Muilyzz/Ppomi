// The evidence column as markup: every OCR word at the screenshot's own position, one reading per shared row, anomalies boxed.
// Ported from report.py column_html minus its title tooltips (no browser-default UI); Tests/column-parity.json holds its
// output (image data and titles stripped). The page's script
// (Web/evidence.html) reads this markup: data-src names the frame a row came from, data-b its box, for colour and size.
import AppKit

enum Column {
    static let frameH = 766.0, frameW = 348.0          // displayed frame size in px (half the PNG); OCR coords are normalized

    struct Built {
        let html: String
        let drawn: Int                                  // transactions whose first row carries an anchor id
        let anomalies: Int                              // amber + red boxes
    }

    /// report.py's evid_id: "ev-" + the uid with every non-word character turned into "_".
    static func evidID(_ uid: String) -> String {
        "ev-" + String(uid.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// html.escape(s, quote=True)
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;")
    }

    /// One JPEG data URI per placed frame, for the peek. Same bytes for the same file, cached for the app's life.
    nonisolated(unsafe) private static var jpegs: [URL: String] = [:]
    static func jpeg(_ png: URL) -> String {
        if let j = jpegs[png] { return j }
        guard let img = NSImage(contentsOf: png), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return "" }
        let out = "data:image/jpeg;base64," + data.base64EncodedString()
        jpegs[png] = out
        return out
    }

    private static func px0(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func px1(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func f4(_ v: Double) -> String { String(describing: (v * 10000).rounded() / 10000) }

    /// Frames registered by `Stitch.place`: a row shared by overlapping frames is drawn once (the topmost frame's reading),
    /// and the app's chrome (status bar, nav, filter bar, floating buttons) is left out. The text itself is the OCR evidence,
    /// so a row that became a ledger line gets no mark; only anomalies are boxed: amber = parsed but not stored, red = an
    /// amount row nothing parsed. A transaction's first row carries the id the journal's "근거" jumps to.
    static func build(app: String, placed: [Stitch.Placed], frames: [Stitch.Frame], inDB: Set<String>) -> Built {
        let base = placed.map { $0.top + $0.clip }.min() ?? 0
        let height = (placed.map { $0.top + $0.bottom }.max() ?? 0) - base
        let imgs = placed.enumerated().map { k, p in "<img id=\"im-\(app)-\(k)\" src=\"\(jpeg(frames[p.frame].png))\" hidden>" }
        var rows: [String] = [], boxes: [String] = [], drawn = Set<String>(), warned = Set<String>(), red = Set<String>(), taken: [Double] = []
        // alignment from the boxes: the x where most rows' last word ends is the list's right margin; a word ending there is
        // right-aligned and gets anchored by its right edge, so its digits end exactly where the app ends them
        var ends: [Double] = []
        for p in placed {
            let f = frames[p.frame]
            for (i, ws) in f.words.enumerated() where p.clip <= f.ys[i].0 && f.ys[i].0 < p.bottom {
                if let w = ws.last { ends.append(((w.x + w.w) * 100).rounded() / 100) }
            }
        }
        var count: [Double: Int] = [:]
        for e in ends { count[e, default: 0] += 1 }
        let rightMargin = count.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 1.0
        for (k, p) in placed.enumerated().reversed() {           // topmost frame first: its reading of a shared row wins
            let f = frames[p.frame], top = p.top - base, clip = p.clip, bottom = p.bottom
            var spans: [Int: OCR.Tx] = [:]
            for t in f.tx { for i in t.rows { spans[i] = t } }
            for (i, ws) in f.words.enumerated() {
                let (y0, y1) = f.ys[i], r = f.rows[i]
                guard clip <= y0, y0 < bottom, r.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                      Stitch.bottom.search(r) == nil, !taken.contains(where: { abs(top + y0 - $0) < 0.012 }) else { continue }
                taken.append(top + y0)
                var rid = ""
                if let t = spans[i], t.rows.lowerBound == i, !drawn.contains(t.uid) { drawn.insert(t.uid); rid = " id=\"\(evidID(t.uid))\"" }
                // positions are the screenshot's. Colour and size are not rules: at load, the page samples each word's ink colour
                // from the frame it was read from and fits the font size so the rendered width matches the OCR box.
                let words = ws.map { w -> String in
                    let pos = abs(w.x + w.w - rightMargin) < 0.012 ? "right:\(px0((1 - w.x - w.w) * frameW))px" : "left:\(px0(w.x * frameW))px"
                    return "<span style=\"\(pos);top:\(px0((w.y - y0) * frameH))px\" data-b=\"\(String(format: "%.4f,%.4f,%.4f,%.4f", w.x, w.y, w.w, w.h))\">\(esc(w.text))</span>"
                }.joined()
                rows.append("<div class=\"row\"\(rid) data-src=\"im-\(app)-\(k)\" style=\"top:\(px0((top + y0) * frameH))px;height:\(px0((y1 - y0) * frameH))px\">\(words)</div>")
            }
            for t in f.tx {
                let (a, b) = (t.rows.lowerBound, t.rows.upperBound)
                if f.ys[a].0 < clip || f.ys[b].1 > bottom || inDB.contains(t.uid) || warned.contains(t.uid) { continue }
                warned.insert(t.uid)
                let y0 = f.ys[a].0, y1 = f.ys[b].1
                boxes.append("<div class=\"box warn\" style=\"top:\(px1((top + y0) * frameH))px;height:\(px1((y1 - y0) * frameH))px\"></div>")
            }
            for (i, r) in f.rows.enumerated() {
                let m = OCR.kbWon.match(r)
                let pair = OCR.txAmt.match(r) != nil && OCR.txMeta.match(r) == nil && i + 1 < f.rows.count && OCR.txMeta.match(f.rows[i + 1]) != nil
                let signed = m.map { !($0[1] ?? "").isEmpty } ?? false
                if (pair || signed), !f.tx.contains(where: { $0.rows.contains(i) }), clip <= f.ys[i].0, f.ys[i].0 < bottom, !red.contains(r) {
                    red.insert(r)
                    let (y0, y1) = f.ys[i]
                    boxes.append("<div class=\"box bad\" style=\"top:\(px1((top + y0) * frameH))px;height:\(px1((y1 - y0) * frameH))px\"></div>")
                }
            }
        }
        let framesJS = "[" + placed.map { "[\(f4($0.top - base)), \(f4($0.clip)), \(f4($0.bottom))]" }.joined(separator: ", ") + "]"
        let col = (["<div class=\"col\" data-app=\"\(app)\" data-frames='\(framesJS)' style=\"height:\(px0(height * frameH))px\">"] + imgs + boxes + rows
                   + ["<div class=\"peek\"><img></div>", "</div>"]).joined(separator: "\n")
        return Built(html: col, drawn: drawn.count, anomalies: warned.count + red.count)
    }
}
