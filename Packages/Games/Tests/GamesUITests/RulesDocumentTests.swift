// RulesDocument tests (task 6.6) — the pure rules-doc loader behind the in-place inspector (R-APP-3.2).
//
// The inspector VIEW is a thin SwiftUI shell; the load path that must be correct — locate the doc for a
// game id, decode its markdown, expose a title, and fail gracefully on an unknown/undecodable doc — is
// pure and tested here through the `RulesDocumentSource` seam with in-memory fixtures (no bundle, no disk).

import Foundation
import Testing

@testable import GamesUI

@Suite("RulesDocument — pure loader (R-APP-3.2)")
struct RulesDocumentTests {

    private func loader(_ fixtures: [String: String]) -> RulesDocumentLoader {
        RulesDocumentLoader(source: InMemoryRulesDocumentSource(markdownByGameID: fixtures))
    }

    @Test("loads the markdown for a known game id")
    func loadsKnownDoc() {
        let markdown = "# Klondike\n\nMove all cards home."
        let loader = loader(["klondike": markdown])

        let result = loader.load(gameID: "klondike", title: "Klondike")
        guard case .success(let doc) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(doc.gameID == "klondike")
        #expect(doc.title == "Klondike")
        #expect(doc.markdown == markdown)
    }

    @Test("an unknown game id fails with notFound (no crash)")
    func unknownGameNotFound() {
        let result = loader(["klondike": "# K"]).load(gameID: "euchre")
        #expect(result == .failure(.notFound(gameID: "euchre")))
    }

    @Test("undecodable bytes fail with unreadable")
    func invalidUTF8IsUnreadable() {
        // A lone continuation byte (0x80) is not valid UTF-8.
        let source = ByteSource(bytes: ["klondike": Data([0x80])])
        let result = RulesDocumentLoader(source: source).load(gameID: "klondike")
        #expect(result == .failure(.unreadable(gameID: "klondike")))
    }

    @Test("derives a readable title from a kebab-case id when none is supplied")
    func derivesTitle() {
        let result = loader(["crazy-eights": "# rules"]).load(gameID: "crazy-eights")
        guard case .success(let doc) = result else {
            Issue.record("expected success")
            return
        }
        #expect(doc.title == "Crazy Eights")
    }

    @Test("derivedTitle capitalizes each hyphen-separated word")
    func derivedTitleHelper() {
        #expect(RulesDocumentLoader.derivedTitle(fromGameID: "klondike") == "Klondike")
        #expect(RulesDocumentLoader.derivedTitle(fromGameID: "crazy-eights") == "Crazy Eights")
        #expect(RulesDocumentLoader.derivedTitle(fromGameID: "gin-rummy") == "Gin Rummy")
    }

    /// A tiny source that returns raw (possibly invalid-UTF-8) bytes for a game id.
    private struct ByteSource: RulesDocumentSource {
        let bytes: [String: Data]
        func data(forGameID gameID: String) -> Data? { bytes[gameID] }
    }
}
