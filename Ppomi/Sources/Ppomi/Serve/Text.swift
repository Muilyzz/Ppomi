// The HTML the reports speak (b, i, pre, tg-spoiler — kept from the Telegram days: MCP and the ring flatten it with plain),
// and Notify: a macOS notification. Named HTML, not Text: a module-level `Text` would shadow SwiftUI.Text in every view.
import Foundation

enum HTML {
    static func esc(_ s: Any) -> String {
        "\(s)".replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    /// Bold won; under a spoiler so a glance at the phone doesn't reveal balances.
    static func won(_ n: Int, hide: Bool = false) -> String {
        let s = "<b>\(n.won)</b>"
        return hide ? "<tg-spoiler>\(s)</tg-spoiler>" : s
    }
    /// Strip our own tags for the ring's caption, macOS notifications, MCP elicitation text.
    static func plain(_ html: String) -> String {
        Re("<[^>]+>").sub(html, "").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// A macOS notification. `body` may carry our HTML.
enum Notify {
    static func post(_ title: String, _ body: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")   // strings as argv, never spliced into the script
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run",
                       String(HTML.plain(body).prefix(200)), title]
        try? p.run()
    }
}
