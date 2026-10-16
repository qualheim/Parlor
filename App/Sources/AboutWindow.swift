// AboutWindow — the standard macOS About window with third-party notices (R-APP-6.3).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// R-APP-6.3: the app provides an About window with third-party notices. macOS already gives every app an
// "About Parlor" item in the app menu via `orderFrontStandardAboutPanel`; we augment it with the credits
// content — the bundled `THIRD_PARTY_NOTICES.md` (audio/assets/licences, R-DS-5.1) rendered as attributed
// text — so a single About surface shows both the app info and the notices. The notices file is bundled as
// a resource by project.yml; if it is missing the panel still shows the standard info (never a crash).

import AppKit
import SwiftUI

/// Opens the standard About panel, injecting the bundled third-party notices as its credits (R-APP-6.3).
///
/// Called from the app-menu About command (see `ParlorApp`/`ParlorCommands`). Reads
/// `THIRD_PARTY_NOTICES.md` from the app bundle, renders it to an `NSAttributedString`, and hands it to
/// `NSApplication.orderFrontStandardAboutPanel` as `.credits` so the notices appear in the familiar macOS
/// About window alongside the app name, version, and copyright.
@MainActor
enum AboutPanel {
    /// Show the About panel with third-party notices as credits (R-APP-6.3).
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let credits = creditsAttributedString() {
            options[.credits] = credits
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    /// Load `THIRD_PARTY_NOTICES.md` from the bundle and render it as attributed text, or `nil` if it is
    /// absent/unreadable (the panel then shows the standard info without notices).
    private static func creditsAttributedString() -> NSAttributedString? {
        guard
            let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        // Render CommonMark to attributed text; fall back to plain text if parsing fails.
        if let attributed = try? NSAttributedString(
            markdown: Data(markdown.utf8),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            return attributed
        }
        return NSAttributedString(string: markdown)
    }
}
