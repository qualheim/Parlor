// FirstRunTour — the pure model behind the ≤ 3-step, skippable first-run tour (R-APP-7.1).
//
// The first launch shows a short welcome tour: AT MOST 3 STEPS, and SKIPPABLE at any point (R-APP-7.1;
// `ux-guidelines.md`). The SwiftUI overlay that draws a step is a thin shell in App/Sources; the parts
// that must be correct and testable — the bounded step list, the "seen" flag, and the advance/skip/finish
// state machine — live here as pure, Foundation-only values so they are exercised headless.
//
// SEEN FLAG (R-APP-7.1). Whether the tour has already been shown is a single persisted `Bool`. Persistence
// has no tour type, so the App stores this flag alongside its other UI state (e.g. in UserDefaults or an
// app-owned settings extension); this model just decides — given the flag — whether to present the tour,
// and reports when it has finished so the App flips the flag. Keeping the decision here (not in the view)
// makes "show once, never again, and Skip counts as seen" testable without any UI or storage.

import Foundation

// MARK: - Tour step

/// One step of the first-run tour: a title, a body line, and an optional SF Symbol the App draws
/// (R-APP-7.1).
///
/// UI-free data (the `symbolName` is just a string the App resolves to an image, like `TileArt`), so the
/// step list is a plain value the model can bound to ≤ 3 and a test can assert.
public struct TourStep: Hashable, Sendable, Identifiable {
    /// A stable id for the step within the tour (e.g. `"welcome"`).
    public let id: String
    /// The step's headline (e.g. "Welcome to Parlor").
    public let title: String
    /// The step's one- or two-line body.
    public let body: String
    /// An optional SF Symbol name the App renders above the text.
    public let symbolName: String?

    public init(id: String, title: String, body: String, symbolName: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.symbolName = symbolName
    }
}

// MARK: - FirstRunTour (the bounded, skippable model)

/// The pure first-run-tour model: a bounded, skippable sequence of steps plus the advance/skip/finish
/// state machine (R-APP-7.1).
///
/// Construct it with the steps to show; the initializer ENFORCES the ≤ 3-step cap (R-APP-7.1) by keeping
/// only the first three, so an over-long list can never reach the UI. `currentIndex` tracks position;
/// `advance()` moves forward and finishes past the last step; `skip()` finishes immediately (Skip counts
/// as "seen"). `isFinished` reports completion so the App persists the seen flag exactly once.
public struct FirstRunTour: Sendable, Equatable {
    /// The hard cap on tour steps (R-APP-7.1).
    public static let maxSteps = 3

    /// The steps to present, already capped to `maxSteps` in display order.
    public let steps: [TourStep]

    /// The index of the step currently shown, or `steps.count` once the tour has finished.
    public private(set) var currentIndex: Int

    /// Whether the tour was ended by an explicit Skip (vs walking through every step). Metadata for the
    /// App; either way the tour is finished and the seen flag should be set.
    public private(set) var didSkip: Bool

    /// Create a tour from `steps`, keeping at most `maxSteps` (R-APP-7.1). An empty list yields an
    /// already-finished tour (nothing to show).
    public init(steps: [TourStep]) {
        self.steps = Array(steps.prefix(FirstRunTour.maxSteps))
        self.currentIndex = 0
        self.didSkip = false
    }

    // MARK: Presentation decision (the "seen" flag)

    /// Whether the tour should be presented, given whether it has already been `seen` (R-APP-7.1).
    ///
    /// The App holds the persisted seen flag; this keeps the "show once, and only if there is something to
    /// show" rule in one testable place. Returns `false` when already seen or when there are no steps.
    public static func shouldPresent(seen: Bool, steps: [TourStep]) -> Bool {
        !seen && !steps.isEmpty
    }

    // MARK: State

    /// The step currently shown, or `nil` once the tour has finished.
    public var currentStep: TourStep? {
        guard currentIndex >= 0, currentIndex < steps.count else { return nil }
        return steps[currentIndex]
    }

    /// Whether the tour has finished (walked past the last step or been skipped).
    public var isFinished: Bool {
        currentIndex >= steps.count
    }

    /// Whether the current step is the last one (the App labels its button "Done" instead of "Next").
    public var isOnLastStep: Bool {
        !steps.isEmpty && currentIndex == steps.count - 1
    }

    /// 1-based position for a progress indicator (e.g. "2 of 3"); `0` once finished.
    public var stepNumber: Int {
        isFinished ? 0 : currentIndex + 1
    }

    // MARK: Transitions

    /// Advance to the next step, finishing the tour once past the last step (R-APP-7.1).
    ///
    /// A no-op when already finished. Returns `true` if the tour is now finished (so the App persists the
    /// seen flag and dismisses the overlay).
    @discardableResult
    public mutating func advance() -> Bool {
        guard !isFinished else { return true }
        currentIndex += 1
        return isFinished
    }

    /// Skip the rest of the tour, finishing it immediately (R-APP-7.1). A no-op when already finished;
    /// records `didSkip` so the App knows it was skipped (the seen flag is set either way).
    public mutating func skip() {
        guard !isFinished else { return }
        currentIndex = steps.count
        didSkip = true
    }
}

// MARK: - Bundled tour (the steps this build shows)

extension FirstRunTour {
    /// The tour this build presents on first launch — exactly three short, skippable steps (R-APP-7.1).
    ///
    /// Original copy written for Parlor; the App renders each step as a standard SwiftUI card over the
    /// library and persists the seen flag when the tour finishes. Kept as a static value so it is the same
    /// in the app and in tests that assert the ≤ 3-step cap.
    public static var bundled: FirstRunTour {
        FirstRunTour(steps: [
            TourStep(
                id: "welcome",
                title: "Welcome to Parlor",
                body:
                    "A quiet place for classic card and tile games. Everything runs on your Mac — "
                    + "nothing leaves it.",
                symbolName: "suit.club.fill"),
            TourStep(
                id: "library",
                title: "Pick a game",
                body: "Browse the library, tweak the rules in the setup sheet, and deal. Your game "
                    + "saves itself as you play.",
                symbolName: "square.grid.2x2.fill"),
            TourStep(
                id: "table",
                title: "At the table",
                body:
                    "Drag or use the keyboard, undo freely, and press ⌘? any time to read the rules "
                    + "without leaving your game.",
                symbolName: "rectangle.on.rectangle.angled.fill"),
        ])
    }
}
