// RulesInspectorView — the in-place rules inspector on the table screen (R-APP-3.2).
//
// NOTE ON BUILD: like the rest of App/Sources, this file is compiled by the XcodeGen-generated Xcode
// project, NOT by SwiftPM (`swift build`/`make build` do not compile App/Sources; design.md §1). It is
// written to match the real GamesUI APIs (`RulesDocumentLoader`, `RulesDocument`, `RulesLoadError`,
// `BundleRulesDocumentSource`) so it compiles cleanly under the app build.
//
// R-APP-3.2: the rules viewer opens IN PLACE AS AN INSPECTOR, rendered from the bundled
// `Docs/Rules/<game-id>.md`, WITHOUT losing game state. This view is presented via SwiftUI's native
// `.inspector(isPresented:)` from the table screen (see `TableScreen`), so the table — and the live
// `GameHost` behind it — is never torn down while the rules are shown; closing the inspector returns to
// exactly the same game. The heavy lifting (locate + read + decode the doc) is the pure
// `RulesDocumentLoader` in GamesUI, tested headless; this view only renders the returned markdown with
// SwiftUI's built-in CommonMark support and shows a calm note if the doc is unavailable.

import GamesUI  // RulesDocumentLoader, RulesDocument, BundleRulesDocumentSource
import SwiftUI

/// The content of the in-place rules inspector for one game (R-APP-3.2).
///
/// Given a game id (and optional catalog title), it loads the bundled rules markdown through the pure
/// `RulesDocumentLoader` and renders it. It holds NO game state — the table owns that — so presenting or
/// dismissing this inspector never disturbs the running game (R-APP-3.2).
struct RulesInspectorView: View {
    /// The game whose rules to show (e.g. `"klondike"`).
    let gameID: String
    /// The catalog display name for the header, or `nil` to derive it from the id.
    let title: String?

    /// The loader reads the bundled `Docs/Rules/<game-id>.md` (copied under the "Rules" bundle folder by
    /// project.yml). Production uses the main bundle; a preview/test could inject an in-memory source.
    private let loader = RulesDocumentLoader(
        source: BundleRulesDocumentSource(bundle: .main, subdirectory: "Rules"))

    var body: some View {
        Group {
            switch loader.load(gameID: gameID, title: title) {
            case .success(let doc):
                loaded(doc)
            case .failure:
                unavailable
            }
        }
        .frame(minWidth: 320)
    }

    /// The rendered rules: a header plus the scrollable markdown body.
    private func loaded(_ doc: RulesDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(doc.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                // SwiftUI renders CommonMark natively; splitting on blank lines keeps paragraph spacing
                // readable for a long rules document.
                ForEach(Array(paragraphs(of: doc.markdown).enumerated()), id: \.offset) { _, para in
                    Text(attributed(para))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    /// A calm "rules unavailable" note — opening the inspector must never crash or disturb the game
    /// (R-APP-3.2).
    private var unavailable: some View {
        ContentUnavailableView(
            "Rules unavailable",
            systemImage: "book.closed",
            description: Text("The rules for this game could not be loaded."))
    }

    /// Split raw markdown into paragraph-ish chunks on blank lines so long docs render with spacing.
    private func paragraphs(of markdown: String) -> [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Render one markdown chunk as an `AttributedString`, falling back to plain text if it cannot parse.
    private func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
