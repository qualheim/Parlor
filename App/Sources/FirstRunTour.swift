// FirstRunTourView + FirstRunTourStore — the ≤ 3-step, skippable first-run tour UI (R-APP-7.1).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1). It is written against the
// real GamesUI `FirstRunTour` / `TourStep` model (the bounded, skippable state machine, tested headless in
// GamesUITests) — this file is only the thin SwiftUI overlay + the persisted "seen" flag.
//
// R-APP-7.1: at most 3 SKIPPABLE steps on first launch. The bounded step list and the advance/skip/finish
// logic live in the pure `FirstRunTour` model; here we (a) persist a single "seen" `Bool` so the tour
// shows once and never again, and (b) draw each step as a standard SwiftUI card over the library with
// Next/Done and a Skip affordance. Skip and walking to the end both finish the tour, which flips the seen
// flag (so Skip counts as seen, per the model).

import GamesUI  // FirstRunTour, TourStep
import Observation
import SwiftUI

// MARK: - Seen-flag store (persisted once)

/// Persists whether the first-run tour has been shown (R-APP-7.1).
///
/// A single `Bool` under one UserDefaults key in the sandbox container (local-only; R-PERS-3.1). Kept tiny
/// and separate because Persistence has no tour type — the pure `FirstRunTour` model decides *whether* to
/// present given this flag (`FirstRunTour.shouldPresent(seen:steps:)`), and flips it when the tour finishes.
@MainActor
@Observable
final class FirstRunTourStore {
    /// The persisted "already shown" flag.
    private(set) var hasSeenTour: Bool

    private let defaults: UserDefaults
    private static let key = "com.parlor.firstRunTour.seen.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasSeenTour = defaults.bool(forKey: FirstRunTourStore.key)
    }

    /// Mark the tour seen and persist it — called when the tour finishes (walked through or skipped).
    func markSeen() {
        hasSeenTour = true
        defaults.set(true, forKey: FirstRunTourStore.key)
    }
}

// MARK: - Tour overlay (R-APP-7.1)

/// The first-run tour overlay: shows the current step with Next/Done and Skip, driving the pure
/// `FirstRunTour` model (R-APP-7.1).
///
/// Lay it over the library. It presents `FirstRunTour.bundled` (already capped to ≤ 3 steps) and, when the
/// tour finishes, calls `onFinished` so the host flips the seen flag and removes the overlay.
struct FirstRunTourView: View {
    /// Called once when the tour finishes (Done past the last step, or Skip).
    let onFinished: () -> Void

    /// The pure, bounded tour model (≤ 3 steps). Mutated locally as the player advances/skips.
    @State private var tour = FirstRunTour.bundled

    var body: some View {
        ZStack {
            // A dimmed scrim so the short tour reads over the library without hiding it entirely.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { skip() }

            if let step = tour.currentStep {
                card(for: step)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tour.currentIndex)
    }

    /// One tour step card: symbol, title, body, a progress dot row, Skip, and Next/Done.
    private func card(for step: TourStep) -> some View {
        VStack(spacing: 16) {
            if let symbol = step.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text(step.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            // "n of 3" progress dots.
            HStack(spacing: 6) {
                ForEach(0..<tour.steps.count, id: \.self) { i in
                    Circle()
                        .fill(
                            i == tour.currentIndex
                                ? Color.accentColor : Color.secondary.opacity(0.4)
                        )
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("Step \(tour.stepNumber) of \(tour.steps.count)")

            HStack {
                Button("Skip", action: skip)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tour.isOnLastStep ? "Done" : "Next", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 360)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 24, y: 8)
    }

    /// Advance the tour; finish (flip the seen flag, dismiss) once past the last step.
    private func advance() {
        if tour.advance() {
            onFinished()
        }
    }

    /// Skip the rest of the tour and finish immediately (R-APP-7.1).
    private func skip() {
        guard !tour.isFinished else { return }
        tour.skip()
        onFinished()
    }
}
