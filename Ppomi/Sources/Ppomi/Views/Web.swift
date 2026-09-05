// Page templates: Web/<name>.html with theme.css spliced in at /*THEME*/ so every page shares one look.
import Foundation

enum Web {
    /// Ppomi_Ppomi.bundle in Contents/Resources (dist/Ppomi.app, scripts/make-app.sh) or wherever SwiftPM put it.
    static let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Ppomi_Ppomi.bundle")) } ?? Bundle.module
    static func file(_ name: String, _ ext: String) -> String {
        try! String(contentsOf: bundle.url(forResource: name, withExtension: ext, subdirectory: "Web")!, encoding: .utf8)
    }
    /// The template with the shared theme in place; callers then fill their own /*DATA*/ placeholders.
    static func page(_ name: String) -> String {
        file(name, "html").replacingOccurrences(of: "/*THEME*/", with: file("theme", "css"))
    }
}
