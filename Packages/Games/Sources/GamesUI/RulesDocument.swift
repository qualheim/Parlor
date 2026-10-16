// RulesDocument + RulesDocumentLoader — the pure model behind the in-place rules inspector (R-APP-3.2).
//
// The table screen opens the rules as an INSPECTOR IN PLACE, rendered from the bundled
// `Docs/Rules/<game-id>.md`, WITHOUT losing game state (R-APP-3.2; design.md §10). The SwiftUI inspector
// view is a thin shell in App/Sources; the part that must be CORRECT and TESTABLE — locate the doc for a
// game id, read it, and expose its markdown (plus a friendly title) — lives here as a pure model with a
// protocol seam so a test can feed a fixture instead of touching the bundle.
//
// WHY IT LIVES IN GamesUI. GamesUI is the UI-layer package that already imports GamesRules (for game
// metadata) and is where per-family screen wiring belongs (design.md §11). The loader itself imports only
// Foundation — no SwiftUI — so it is a plain, headless-testable value; the App renders the returned
// markdown with SwiftUI's native `Text(markdown:)` / `AttributedString(markdown:)` in the inspector.
//
// THE SEAM. `RulesDocumentSource` abstracts "give me the markdown bytes for this game id". Production uses
// `BundleRulesDocumentSource`, which resolves `Docs/Rules/<game-id>.md` from a resource bundle (the App
// bundles the Docs/Rules directory). Tests use `InMemoryRulesDocumentSource` with a fixture string, so the
// loader's behavior — success, unknown game, decode — is exercised without any file system.

import Foundation
import GamesRules

// MARK: - Loaded rules document

/// The bundled rules for one game, loaded for the in-place inspector (R-APP-3.2).
///
/// A pure value: the game id it belongs to, a display title (the game's catalog name when known, else a
/// title derived from the id), and the raw CommonMark `markdown` read from `Docs/Rules/<game-id>.md`. The
/// inspector view renders `markdown` with SwiftUI's native markdown support; keeping the value UI-free
/// means the load path is fully testable headless.
public struct RulesDocument: Hashable, Sendable {
    /// The stable game id these rules belong to (e.g. `"klondike"`).
    public let gameID: String
    /// A human-readable title for the inspector header (the catalog name, or a derived fallback).
    public let title: String
    /// The raw markdown read from `Docs/Rules/<game-id>.md` (R-APP-3.2).
    public let markdown: String

    public init(gameID: String, title: String, markdown: String) {
        self.gameID = gameID
        self.title = title
        self.markdown = markdown
    }
}

// MARK: - Load failure (typed; the inspector degrades gracefully)

/// Why the rules for a game could not be loaded (R-APP-3.2).
///
/// Returned (never trapped) so the inspector can show a calm "rules unavailable" note instead of crashing
/// — opening the inspector must never disturb the game (R-APP-3.2).
public enum RulesLoadError: Error, Sendable, Equatable {
    /// No `Docs/Rules/<game-id>.md` exists for this game id (unbundled, or an unknown id).
    case notFound(gameID: String)
    /// The document existed but its bytes could not be decoded as UTF-8 text.
    case unreadable(gameID: String)
}

// MARK: - Rules document source (the testable seam)

/// The seam the loader reads bytes through: "give me the markdown data for this game id, or nil"
/// (R-APP-3.2).
///
/// Production resolves the file from a bundle; tests supply fixtures in memory. `Sendable` so the loader
/// (which the App may hold across the main actor) stays `Sendable`.
public protocol RulesDocumentSource: Sendable {
    /// The raw bytes of `Docs/Rules/<gameID>.md`, or `nil` if there is no such document.
    func data(forGameID gameID: String) -> Data?
}

/// An in-memory `RulesDocumentSource` for tests and previews — maps game ids to fixture markdown.
public struct InMemoryRulesDocumentSource: RulesDocumentSource {
    private let documents: [String: Data]

    /// Create a source from `gameID → markdown` fixtures.
    public init(markdownByGameID: [String: String]) {
        self.documents = markdownByGameID.mapValues { Data($0.utf8) }
    }

    public func data(forGameID gameID: String) -> Data? {
        documents[gameID]
    }
}

// MARK: - Rules document loader (R-APP-3.2)

/// Loads a game's bundled rules markdown for the in-place inspector (R-APP-3.2).
///
/// Pure over its injected `RulesDocumentSource`: `load(gameID:title:)` asks the source for the bytes,
/// decodes them as UTF-8, and returns a `RulesDocument` — or a typed `RulesLoadError` the inspector shows
/// as a calm note. The `title` is supplied by the caller (the App passes the catalog name); when omitted a
/// readable title is derived from the id so the inspector header is never empty.
public struct RulesDocumentLoader: Sendable {
    private let source: any RulesDocumentSource

    public init(source: any RulesDocumentSource) {
        self.source = source
    }

    /// Load the rules for `gameID`, using `title` for the header (or a derived fallback) (R-APP-3.2).
    public func load(gameID: String, title: String? = nil) -> Result<RulesDocument, RulesLoadError>
    {
        guard let data = source.data(forGameID: gameID) else {
            return .failure(.notFound(gameID: gameID))
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            return .failure(.unreadable(gameID: gameID))
        }
        return .success(
            RulesDocument(
                gameID: gameID,
                title: title ?? RulesDocumentLoader.derivedTitle(fromGameID: gameID),
                markdown: markdown))
    }

    /// A readable title derived from a kebab-case game id (e.g. `"crazy-eights"` → `"Crazy Eights"`),
    /// used when the caller does not supply the catalog name.
    static func derivedTitle(fromGameID gameID: String) -> String {
        gameID
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
