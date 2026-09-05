// The 뽀미 window's content: the kiosk's ring, one window wide — the same four bands, rim (phase-colored, spanning the hole)
// and phone band around a hole the size of the phone (KioskController.dock keeps the mirroring window over it). The
// workbench is one view the controller moves between this left band and the kiosk's, so the pages survive the switch.
// No × here: the traffic lights are the window's furniture.
import AppKit

final class RingContent: NSView {
    static let rimTop: CGFloat = 32, rimBottom: CGFloat = 96, rimRight: CGFloat = 32, bandMin: CGFloat = 560
    let bands: [RingView] = [NSRectEdge.minY, .maxY, .maxX, .minX].map { let v = RingView(); v.edge = $0; return v }   // top, bottom, left, right
    let hole = DockView()
    let band = PhoneBand()                                  // caption and ask buttons, on the bottom band under the phone
    weak var workbench: NSView?
    var phoneSize = Mirroring.defaultSize { didSet { needsLayout = true } }
    var phase: Phase = .idle { didSet { bands.forEach { $0.phase = phase } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        (bands + [hole]).forEach(addSubview)
        bands[1].addSubview(band)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Content size for a workbench band of `bandWidth` beside a phone of `phone`.
    static func size(bandWidth: CGFloat, phone: CGSize) -> CGSize {
        CGSize(width: bandWidth + phone.width + rimRight, height: phone.height + rimTop + rimBottom)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let h = CGRect(x: b.maxX - Self.rimRight - phoneSize.width, y: Self.rimBottom, width: phoneSize.width, height: phoneSize.height)
        for (v, r) in zip(bands, Ring.rects(around: h, in: b)) { v.frame = r }
        hole.frame = h
        workbench?.frame = bands[2].bounds.insetBy(dx: 12, dy: 12)
        bands[0].rimSpan = h.minX...h.maxX; bands[1].rimSpan = h.minX...h.maxX      // the rim frames the phone, not the window
        band.frame = PhoneBand.frame(underHole: h.minX...h.maxX, in: bands[1].bounds)
    }
}

/// Under the phone, on both rings (the window's bottom band and the kiosk's): the caption — state.statusLine, what was
/// heard, what was said, one line each — and, while another process asks (Tools.askViaDB), the question in plain text
/// over a row of native buttons with a 5-minute clock. The person answers here or in an MCP elicitation, never by voice.
final class PhoneBand: NSView {
    weak var state: AppState?
    private let question = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let clock = NSTextField(labelWithString: "")
    private let caption = NSTextField(wrappingLabelWithString: "")
    private var askID: String?, deadline = Date(), timer: Timer?
    static let lineHeight: CGFloat = 16

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        for t in [question, caption] { t.font = .systemFont(ofSize: 12); t.alignment = .center; t.lineBreakMode = .byTruncatingTail }
        question.textColor = NSColor(white: 1, alpha: 0.9)
        caption.textColor = NSColor(white: 1, alpha: 0.7); caption.maximumNumberOfLines = 3
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); clock.textColor = NSColor(white: 1, alpha: 0.55)
        buttons.orientation = .horizontal; buttons.spacing = 8; buttons.alignment = .centerY
        [question, buttons, caption].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Centered on the hole, widened (within the band) so ask_choice's four buttons fit.
    static func frame(underHole span: ClosedRange<CGFloat>, in band: CGRect) -> CGRect {
        let w = min(band.width, max(span.upperBound - span.lowerBound, 640))
        let x = max(band.minX, min((span.lowerBound + span.upperBound) / 2 - w / 2, band.maxX - w))
        return CGRect(x: x, y: band.minY, width: w, height: band.height)
    }

    /// Pull what the state says now (KioskController.sync calls this on every change).
    func sync() {
        guard let s = state else { return }
        caption.stringValue = [s.statusLine, s.heard, s.said].filter { !$0.isEmpty }.joined(separator: "\n")
        if s.ask?.id != askID {
            askID = s.ask?.id
            buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
            timer?.invalidate(); timer = nil
            question.stringValue = s.ask?.text ?? ""
            if let a = s.ask {
                for (i, o) in a.options.enumerated() {
                    let b = NSButton(title: o, target: self, action: #selector(pressed(_:)))
                    b.bezelStyle = .rounded; b.controlSize = .regular; b.tag = i
                    if i == 0, o.hasPrefix("결제 승인") {                   // the money button: white fill, black text
                        b.bezelColor = .white
                        b.attributedTitle = NSAttributedString(string: o, attributes: [.foregroundColor: NSColor.black, .font: b.font ?? .systemFont(ofSize: 13)])
                    }
                    buttons.addArrangedSubview(b)
                }
                buttons.addArrangedSubview(clock)
                deadline = Date(timeIntervalSinceNow: 300)
                tick()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
        question.isHidden = askID == nil; buttons.isHidden = askID == nil
        needsLayout = true
    }

    private func tick() {
        let left = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        clock.stringValue = String(format: "%d:%02d", left / 60, left % 60)
    }

    @objc private func pressed(_ b: NSButton) {
        guard let s = state, let a = s.ask, b.tag < a.options.count else { return }
        s.answer(a.options[b.tag])
    }

    /// From the top (the phone's bottom edge) down: question, buttons, then the caption's lines.
    override func layout() {
        super.layout()
        var y = bounds.height - 6
        let lh = Self.lineHeight
        if askID != nil {
            question.frame = NSRect(x: 0, y: y - lh, width: bounds.width, height: lh); y -= lh + 4
            buttons.layoutSubtreeIfNeeded()
            let bs = buttons.fittingSize, bw = min(bs.width, bounds.width)
            buttons.frame = NSRect(x: (bounds.width - bw) / 2, y: y - bs.height, width: bw, height: bs.height); y -= bs.height + 4
        }
        let lines = CGFloat(max(1, min(3, caption.stringValue.split(separator: "\n").count)))
        caption.frame = NSRect(x: 0, y: max(0, y - lh * lines), width: bounds.width, height: lh * lines)
    }
}

/// The hole. Black like the bands, so when there is no phone it reads as an empty slot with a hint.
final class DockView: NSView {
    var hint = "" { didSet { if hint != oldValue { needsDisplay = true } } }
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(white: 1, alpha: 0.5), .font: NSFont.systemFont(ofSize: 13), .paragraphStyle: p]
        let t = (hint.isEmpty ? "iPhone 미러링을 실행하면\n그 창이 여기에 붙습니다" : hint) as NSString, h = t.size(withAttributes: a).height
        t.draw(in: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h), withAttributes: a)
    }
}
