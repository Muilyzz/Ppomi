// A page of ours in a WKWebView: HTML built by the app (template + JSON), messages back through webkit.messageHandlers.ppomi.
// A new HTML reloads; a new focus runs the page's focus(id) once the page is there.
import SwiftUI
import WebKit

struct WebPage: NSViewRepresentable {
    let html: String
    var focus: String? = nil
    var onMessage: ((Any) -> Void)? = nil
    var onReady: ((WKWebView) -> Void)? = nil          // the page is loaded: a caller may keep the view to call into it

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ppomi")
        let v = WorkbenchWebView(frame: .zero, configuration: cfg)
        v.underPageBackgroundColor = .black                // no white flash before the page paints
        v.navigationDelegate = context.coordinator
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        c.focus = focus; c.onMessage = onMessage; c.onReady = onReady
        if c.html != html { c.html = html; c.loaded = false; v.loadHTMLString(html, baseURL: nil) }
        else if c.loaded { c.apply(v) }
    }
    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "ppomi")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var html = "", focus: String?, loaded = false, applied: String? = nil
        var onMessage: ((Any) -> Void)?
        var onReady: ((WKWebView) -> Void)?
        func apply(_ v: WKWebView) {
            guard applied != focus else { return }
            applied = focus
            v.evaluateJavaScript("typeof focus==='function'&&focus(\(focus.map { "'\($0)'" } ?? "null"))")
        }
        func webView(_ v: WKWebView, didFinish: WKNavigation!) { loaded = true; applied = nil; apply(v); onReady?(v) }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { onMessage?(m.body) }
    }
}
