// KlondikeWinCelebrationView — the thin SpriteKit overlay shell for Klondike's win celebration (task 5.8;
// R-KLON-3.9).
//
// This is the VIEW half of the win celebration; the brains live in the pure, Foundation-only
// `WinCelebration.swift` (trigger, ≤ 3 s cap, skip, Reduce-Motion style selection). This file is the
// deliberately thin shell that turns the resolved `WinCelebrationController` into pixels:
//
//   • SpriteKit is used ONLY here (design.md §6: "SpriteKit is allowed only for particle/physics overlays
//     like the win celebration"). GamesUI is a UI-layer package, so importing SpriteKit/SwiftUI is allowed
//     — it must never leak into the pure layer (EngineCore/AIKit/GamesRules), which the lint enforces.
//   • The cascade (R-KLON-3.9) is the classic Solitaire bouncing-cards homage: face-up cards launch and
//     bounce down the table under gravity, plus a modern particle sparkle flourish.
//   • Reduce Motion (R-TABLE-5.3, R-A11Y-4.1) → the controller resolves `style == .crossfade`; the scene
//     shows a static "You won" flourish that crossfades in, with NO moving cards or particles, and the
//     "you won" signal is never lost.
//   • Skippable (R-KLON-3.9): a click or space/return ends it early via the controller's `skip()`, reusing
//     TableKit's fast-forward-on-input idea (View.fastForwardOnInput). The overlay also self-dismisses when
//     the ≤ 3 s cap elapses.

import SwiftUI
import SpriteKit
import GamesRules
import TableKit

// MARK: - SwiftUI overlay (the public entry point)

/// A SwiftUI overlay that plays the Klondike win celebration when a win is signalled, then removes itself
/// (R-KLON-3.9). Lay it over the table; it draws nothing until `start(outcome:reduceMotion:)` fires.
///
/// The overlay is driven by a `WinCelebrationCoordinator` (an `@Observable` shell around the pure
/// `WinCelebrationController`). The host starts a celebration on a winning `handEnded`; the overlay plays
/// the SpriteKit scene for the capped duration or until the player skips, then hides.
public struct KlondikeWinCelebrationView: View {
    /// The observable coordinator wrapping the pure controller. The host owns it and calls `start`.
    @State private var coordinator: WinCelebrationCoordinator

    /// A caption shown for the crossfade (Reduce Motion) style so the win reads without motion
    /// (R-A11Y-4.1).
    private let winMessage: String

    /// Whether translucency should fall back to opaque fills (Reduce Transparency — R-A11Y-4.1). Set by
    /// the app shell from the effective accessibility fold; the crossfade banner reads it.
    @Environment(\.reduceTransparency) private var reduceTransparency

    /// Create the overlay bound to a coordinator.
    ///
    /// - Parameters:
    ///   - coordinator: the celebration coordinator (host-owned so it can `start` on a win).
    ///   - winMessage: the localized "you won" text used by the crossfade flourish.
    public init(
        coordinator: WinCelebrationCoordinator,
        winMessage: String = "You won!"
    ) {
        _coordinator = State(initialValue: coordinator)
        self.winMessage = winMessage
    }

    public var body: some View {
        ZStack {
            if coordinator.isPlaying {
                celebrationOverlay
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(coordinator.isPlaying)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isPlaying)
    }

    @ViewBuilder
    private var celebrationOverlay: some View {
        switch coordinator.controller.style {
        case .cascade:
            // The SpriteKit particle/physics overlay: cascading cards + a sparkle flourish.
            SpriteCelebrationView(coordinator: coordinator)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .skipCelebrationOnInput(coordinator)
                .accessibilityLabel(Text(winMessage))
        case .crossfade:
            // Reduce Motion: a static flourish that crossfades in — no cards move, no particles
            // (R-TABLE-5.3). The win signal is the caption + a soft banner (R-A11Y-4.1).
            crossfadeFlourish
                .contentShape(Rectangle())
                .skipCelebrationOnInput(coordinator)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text(winMessage))
        }
    }

    /// The Reduce-Motion flourish: a dimmed scrim and a crossfaded "You won!" banner. No motion beyond the
    /// fade (R-TABLE-5.3); the banner carries the whole signal (R-A11Y-4.1).
    private var crossfadeFlourish: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            Text(winMessage)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .background(bannerBackground)
        }
    }

    /// The win-banner backdrop: a blurred material normally, an opaque dark fill under Reduce Transparency
    /// so nothing shows through (R-A11Y-4.1).
    @ViewBuilder
    private var bannerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if reduceTransparency {
            shape.fill(Color.black.opacity(1.0))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Coordinator (observable shell over the pure controller)

/// The `@MainActor @Observable` shell that gives the pure `WinCelebrationController` a clock and drives the
/// SwiftUI overlay (task 5.8). Same "pure core, thin observable shell" split as `AnimationDriver`.
///
/// It holds the controller value, starts a celebration on a winning outcome, schedules the ≤ 3 s
/// self-dismiss, and exposes `skip()` for the fast-forward-on-input wiring. All timing decisions defer to
/// the pure controller; this only supplies the wall-clock.
@MainActor
@Observable
public final class WinCelebrationCoordinator {
    /// The pure controller (phase, style, capped duration, skip state).
    public private(set) var controller = WinCelebrationController()

    /// A generation token that invalidates a scheduled self-dismiss if the celebration is skipped or reset
    /// first, so a stale timer can't act on a finished/replaced run (mirrors `AnimationDriver.generation`).
    private var generation = 0

    public init() {}

    /// Whether a celebration is on screen (the overlay is visible).
    public var isPlaying: Bool { controller.isPlaying }

    /// Start a celebration for a finished hand, if it was a win (R-KLON-3.9). Resolves the style for the
    /// current Reduce-Motion setting (R-TABLE-5.3) and schedules the ≤ 3 s cap self-dismiss.
    ///
    /// - Returns: `true` iff a celebration actually started (a win, and not already playing).
    @discardableResult
    public func start(outcome: HandOutcome, reduceMotion: Bool) -> Bool {
        guard controller.start(outcome: outcome, reduceMotion: reduceMotion) else { return false }
        generation += 1
        let token = generation
        let cap = controller.duration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, cap) * 1_000_000_000))
            guard let self, self.generation == token else { return }
            self.controller.tick(elapsed: cap)
        }
        return true
    }

    /// Skip the celebration now (a click/keypress; R-KLON-3.9). Invalidates the scheduled self-dismiss.
    public func skip() {
        guard controller.skip() else { return }
        generation += 1  // invalidate the pending cap timer
    }

    /// Reset to idle (e.g. a new deal), discarding any in-flight celebration.
    public func reset() {
        controller.reset()
        generation += 1
    }
}

// MARK: - SpriteKit scene wrapper (the cascade + flourish)

/// The `NSViewRepresentable` that hosts the SpriteKit `SKView` playing the cascade scene. Skipping is
/// handled by the SwiftUI layer (`skipCelebrationOnInput`); this only presents the scene.
private struct SpriteCelebrationView: NSViewRepresentable {
    let coordinator: WinCelebrationCoordinator

    func makeNSView(context: Context) -> SKView {
        let view = SKView()
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        let scene = CascadeCelebrationScene()
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        view.presentScene(scene)
        return view
    }

    func updateNSView(_ nsView: SKView, context: Context) {
        // If the celebration ended (skip or cap), pause the scene so no further physics runs.
        nsView.isPaused = !coordinator.isPlaying
    }
}

/// The SpriteKit scene: the classic cascading-cards homage plus a modern sparkle flourish (R-KLON-3.9).
///
/// Cards launch from near the foundations and bounce down under gravity — the recognizable Solitaire
/// finish — while an emitter adds a brief modern sparkle. The scene is transparent so the table shows
/// through. The scene runs unbounded on its own; the ≤ 3 s cap and skip are enforced by the coordinator,
/// which removes the whole overlay.
private final class CascadeCelebrationScene: SKScene {
    override func didMove(to view: SKView) {
        physicsWorld.gravity = CGVector(dx: 0, dy: -6.5)
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame)
        physicsBody?.friction = 0.2
        launchCascade()
        addFlourish()
    }

    /// Launch a run of bouncing "cards" from near the top toward the bottom, each with a sideways kick so
    /// they fan across the table like the classic finish. Cards are simple rounded rectangles (the homage
    /// reads from motion, not art); production card art is layered in later (🎨 tracked with the deck art).
    private func launchCascade() {
        let cardSize = CGSize(width: 60, height: 84)
        let count = 26
        for i in 0..<count {
            let card = makeCardNode(size: cardSize)
            let startX = size.width * (0.35 + 0.3 * CGFloat(i % 4) / 3)
            card.position = CGPoint(x: startX, y: size.height - cardSize.height)
            card.physicsBody = SKPhysicsBody(rectangleOf: cardSize)
            card.physicsBody?.restitution = 0.55
            card.physicsBody?.friction = 0.15
            card.physicsBody?.linearDamping = 0.1
            addChild(card)
            let kick = CGVector(
                dx: CGFloat.random(in: -140...140), dy: CGFloat.random(in: -20...40))
            let delay = SKAction.wait(forDuration: Double(i) * 0.05)
            let push = SKAction.run { [weak card] in card?.physicsBody?.applyImpulse(kick) }
            card.run(SKAction.sequence([delay, push]))
        }
    }

    /// A single bouncing card node — a rounded rectangle in a card-like fill.
    private func makeCardNode(size: CGSize) -> SKShapeNode {
        let node = SKShapeNode(
            rectOf: size, cornerRadius: min(size.width, size.height) * 0.12)
        node.fillColor = .white
        node.strokeColor = SKColor(white: 0.8, alpha: 1)
        node.lineWidth = 1
        return node
    }

    /// A brief modern sparkle flourish — a short-lived particle burst near the top of the table. Kept
    /// programmatic (no bundled emitter asset) so it needs no production art to run.
    private func addFlourish() {
        let emitter = SKEmitterNode()
        emitter.particleTexture = nil
        emitter.particleColor = SKColor(white: 1, alpha: 0.9)
        emitter.particleColorBlendFactor = 1
        emitter.particleBirthRate = 200
        emitter.numParticlesToEmit = 220
        emitter.particleLifetime = 1.2
        emitter.particleLifetimeRange = 0.4
        emitter.particleSpeed = 180
        emitter.particleSpeedRange = 80
        emitter.emissionAngle = -.pi / 2
        emitter.emissionAngleRange = .pi
        emitter.particleAlpha = 0.9
        emitter.particleAlphaSpeed = -0.8
        emitter.particleScale = 0.06
        emitter.particleScaleRange = 0.04
        emitter.position = CGPoint(x: size.width / 2, y: size.height * 0.85)
        emitter.zPosition = 10
        addChild(emitter)
    }
}

// MARK: - Fast-forward-on-input (skip), mirroring AnimationDriver.fastForwardOnInput

extension View {
    /// Skip the celebration on a click anywhere on this view or on the space/return key (R-KLON-3.9),
    /// reusing TableKit's fast-forward-on-input pattern (`AnimationDriver.fastForwardOnInput`).
    ///
    /// The tap is a plain gesture (the overlay sits above the table and captures input while playing); the
    /// key handler covers keyboard-only play (R-A11Y-2) — space or return dismisses the celebration.
    fileprivate func skipCelebrationOnInput(_ coordinator: WinCelebrationCoordinator) -> some View {
        self
            .onTapGesture { coordinator.skip() }
            .onKeyPress { press in
                guard coordinator.isPlaying else { return .ignored }
                switch press.key {
                case .space, .return:
                    coordinator.skip()
                    return .handled
                default:
                    return .ignored
                }
            }
    }
}
