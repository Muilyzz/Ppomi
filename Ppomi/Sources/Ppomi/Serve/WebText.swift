// A page's visible text, rendered (SPAs included) by an off-screen WKWebView on the main thread. Blocks the caller.
import Foundation
import WebKit

enum WebText {
    private final class Done: NSObject, WKNavigationDelegate {
        var finish: ((String) -> Void)?
        func webView(_ v: WKWebView, didFinish: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {   // let the app's own scripts fill the page
                v.evaluateJavaScript("document.body.innerText") { r, _ in self.finish?((r as? String) ?? "") }
            }
        }
        func webView(_ v: WKWebView, didFail: WKNavigation!, withError e: Error) { finish?("(load failed: \(e.localizedDescription))") }
        func webView(_ v: WKWebView, didFailProvisionalNavigation: WKNavigation!, withError e: Error) { finish?("(load failed: \(e.localizedDescription))") }
    }
    nonisolated(unsafe) private static var view: WKWebView?, delegate = Done()

    static func read(_ url: String, timeout: TimeInterval = 30) -> String {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return "(bad url)" }
        let sem = DispatchSemaphore(value: 0)
        var out = "(timeout)"
        DispatchQueue.main.async {
            if view == nil { view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900)); view!.navigationDelegate = delegate }
            delegate.finish = { t in out = t; delegate.finish = nil; sem.signal() }
            view!.load(URLRequest(url: u))
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { DispatchQueue.main.async { delegate.finish = nil } }
        return out.replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
    }
}
