// BundleRulesDocumentSource — the production `RulesDocumentSource` that resolves the bundled rules docs
// (R-APP-3.2).
//
// The App bundles the repository's `Docs/Rules/` directory (klondike.md, crazy-eights.md, …) as a
// resource; this source looks a game id up as `<gameID>.md` inside that bundled subdirectory and returns
// its bytes. It imports only Foundation, so it stays headless-testable via `Bundle`, and it never touches
// anything outside the given bundle (App Sandbox friendly, R-BUILD-3.1).
//
// The App constructs one with the App bundle (`Bundle.main`) and the subdirectory it copied the rules
// into (default `"Rules"`, since resource folder references flatten to their own name). The pure
// `RulesDocumentLoader` reads through this source, so the whole load path is the same in tests (in-memory
// fixtures) and production (this bundle source).

import Foundation

/// A `RulesDocumentSource` backed by a resource `Bundle` (R-APP-3.2).
///
/// Resolves `Docs/Rules/<gameID>.md` as a bundled resource named `<gameID>.md` inside `subdirectory`
/// (default `"Rules"`). Returns `nil` when the resource is absent — the loader turns that into
/// `RulesLoadError.notFound`, which the inspector shows as a calm note rather than crashing (R-APP-3.2).
public struct BundleRulesDocumentSource: RulesDocumentSource {
    private let bundle: Bundle
    private let subdirectory: String?

    /// Create a source resolving `<gameID>.md` from `bundle`, optionally within `subdirectory`.
    ///
    /// - Parameters:
    ///   - bundle: the resource bundle holding the rules docs (the App passes `Bundle.main`).
    ///   - subdirectory: the folder the docs were bundled under (default `"Rules"`), or `nil` if the
    ///     `.md` files sit at the bundle root.
    public init(bundle: Bundle, subdirectory: String? = "Rules") {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    public func data(forGameID gameID: String) -> Data? {
        guard
            let url = bundle.url(
                forResource: gameID, withExtension: "md", subdirectory: subdirectory)
        else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
