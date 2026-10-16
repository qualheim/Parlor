// HUDView — the SwiftUI HUD shell over the pure `HUDModel` (task 5.6; R-TABLE-6.1–6.3).
//
// R-TABLE-6.1 requires six HUD components — seat plates, a scoreboard, a caption bar, a history drawer, a
// pause menu, and a toolbar (New/Undo/Hint/Rules/Menu). This file provides each as a thin SwiftUI view
// over the pure value types in `HUDModel.swift`, plus a composing `TableHUDView` that lays them into the
// reserved edge chrome regions (`HUDLayout`) so the HUD never covers the cards a player needs (R-TABLE-6.3).
//
// The design mirrors the rest of TableKit: every decision (plate contents, active-turn/thinking flags,
// scoreboard order, history narration, region geometry) is computed in the pure layer and unit-tested
// headless; these views only draw the result. Seat plates sit at the exact `SeatArrangement` anchors the
// renderer uses (local player bottom-center, others clockwise — R-TABLE-6.2). Colors and metrics come from
// DesignSystem tokens read through the `.designTokens` environment (R-DS-1.2); nothing here names a raw
// color or magic number. The caption bar reuses the illegal-move caption styling established in
// `TableInteractionView` (R-TABLE-4.1) and also carries event narration (R-TABLE-6.1).

import DesignSystem
import EngineCore
import SwiftUI

// MARK: - Seat plate (R-TABLE-6.2)

/// A single seat plate: avatar, name, score, dealer button, role badges, active-turn glow, and an AI
/// thinking indicator (R-TABLE-6.2). A pure function of a `SeatPlateState`.
public struct SeatPlateView: View {
    private let state: SeatPlateState

    @Environment(\.designTokens) private var tokens
    @Environment(\.reduceTransparency) private var reduceTransparency

    /// Create a seat plate for the given state.
    public init(state: SeatPlateState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            avatar
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(state.profile.displayName)
                    .font(Typography.headline.swiftUIFont)
                    .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                    .lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Text("\(state.score)")
                        .font(Typography.callout.swiftUIFont)
                        .foregroundStyle(tokens.swiftUIColor(.textSecondary))
                        .monospacedDigit()
                    ForEach(Array(state.roles.enumerated()), id: \.offset) { _, role in
                        roleBadge(role)
                    }
                }
            }
            Spacer(minLength: 0)
            if state.isDealer { dealerButton }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(plateBackground)
        .overlay(activeTurnGlow)
        .overlay(alignment: .topTrailing) { thinkingIndicator }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(state.accessibilitySummary))
    }

    // MARK: Pieces

    private var avatar: some View {
        HUDAvatarView(reference: state.profile.avatar, size: 40)
    }

    private var dealerButton: some View {
        // The dealer "button" — a small D disc, the traditional dealer marker (R-TABLE-6.2).
        Text("D")
            .font(Typography.caption.swiftUIFont.weight(.bold))
            .foregroundStyle(tokens.swiftUIColor(.textOnAccent))
            .frame(width: 20, height: 20)
            .background(tokens.swiftUIColor(.accent), in: Circle())
            .overlay(Circle().strokeBorder(tokens.swiftUIColor(.controlBorder), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func roleBadge(_ role: SeatRole) -> some View {
        Text(role.label)
            .font(Typography.caption.swiftUIFont.weight(.semibold))
            .foregroundStyle(tokens.swiftUIColor(.textOnAccent))
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(
                tokens.swiftUIColor(.accent),
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var plateBackground: some View {
        // Translucent plate normally; opaque under Reduce Transparency so nothing shows through
        // (R-A11Y-4.1).
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(
                tokens.swiftUIColor(.surfaceElevated)
                    .opacity(
                        backdropOpacity(reduceTransparency: reduceTransparency, translucent: 0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(tokens.swiftUIColor(.controlBorder).opacity(0.5), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(Elevation.low.opacity),
                radius: Elevation.low.radius,
                x: Elevation.low.offsetX,
                y: Elevation.low.offsetY)
    }

    @ViewBuilder
    private var activeTurnGlow: some View {
        if state.isActiveTurn {
            // The active-turn glow — a bright accent ring drawn around the plate (R-TABLE-6.2).
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(tokens.swiftUIColor(.accent), lineWidth: 3)
                .shadow(color: tokens.swiftUIColor(.accent).opacity(0.7), radius: 8)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var thinkingIndicator: some View {
        if state.isThinking {
            // The AI thinking indicator — an animated "…" pill (R-TABLE-6.2).
            ThinkingDotsView()
                .padding(Spacing.xs)
                .background(tokens.swiftUIColor(.surface), in: Capsule())
                .overlay(Capsule().strokeBorder(tokens.swiftUIColor(.controlBorder), lineWidth: 1))
                .offset(x: 6, y: -6)
                .accessibilityLabel(Text("Thinking"))
        }
    }
}

/// A small animated three-dot "thinking" indicator (R-TABLE-6.2). Honors Reduce Motion: when motion is
/// reduced the dots simply hold (no pulsing), preserving the meaning without animation (R-TABLE-5.3).
struct ThinkingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion ? 0.7 : (phase == i ? 1 : 0.3))
            }
        }
        .foregroundStyle(.secondary)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                phase = 2
            }
        }
    }
}

// MARK: - Scoreboard (R-TABLE-6.1)

/// The scoreboard: each seat's name and cumulative score, leader highlighted, plus the hands-played count
/// (R-TABLE-6.1). A pure function of a `ScoreboardModel`.
public struct ScoreboardView: View {
    private let model: ScoreboardModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.reduceTransparency) private var reduceTransparency

    public init(model: ScoreboardModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Scores")
                    .font(Typography.caption.swiftUIFont.weight(.semibold))
                    .foregroundStyle(tokens.swiftUIColor(.textSecondary))
                Spacer(minLength: Spacing.sm)
                Text(model.isMatchOver ? "Final" : "Hand \(model.handsPlayed + 1)")
                    .font(Typography.caption.swiftUIFont)
                    .foregroundStyle(tokens.swiftUIColor(.textSecondary))
            }
            ForEach(model.rows) { row in
                HStack(spacing: Spacing.sm) {
                    if row.isLeader {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(tokens.swiftUIColor(.warning))
                            .accessibilityHidden(true)
                    }
                    Text(row.name)
                        .font(Typography.callout.swiftUIFont)
                        .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.md)
                    Text("\(row.score)")
                        .font(Typography.callout.swiftUIFont.weight(.semibold))
                        .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        "\(row.name), \(row.score) points\(row.isLeader ? ", leading" : "")"))
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(
                    tokens.swiftUIColor(.surfaceElevated)
                        .opacity(
                            backdropOpacity(
                                reduceTransparency: reduceTransparency, translucent: 0.94))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(tokens.swiftUIColor(.controlBorder).opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Caption bar (R-TABLE-6.1; reuses R-TABLE-4.1 styling)

/// The caption bar: a transient, non-modal narration line (R-TABLE-6.1). Reuses the illegal-move caption
/// styling from `TableInteractionView` (R-TABLE-4.1) — a dark capsule with light text — and here also
/// carries event narration (a trick won, a suit named, a hand result).
public struct CaptionBarView: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.callout.swiftUIFont.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .accessibilityLabel(Text(text))
            .transition(.opacity)
    }
}

// MARK: - History drawer (R-TABLE-6.1)

/// The history drawer: a scrollable, chronological list of the match's narrated events (R-TABLE-6.1). A
/// pure function of `[HistoryEntry]`.
public struct HistoryDrawerView: View {
    private let entries: [HistoryEntry]
    private let onClose: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.reduceTransparency) private var reduceTransparency

    public init(entries: [HistoryEntry], onClose: @escaping () -> Void = {}) {
        self.entries = entries
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("History")
                    .font(Typography.headline.swiftUIFont)
                    .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.swiftUIColor(.textSecondary))
                .accessibilityLabel(Text("Close history"))
            }
            Divider().overlay(tokens.swiftUIColor(.separator))
            if entries.isEmpty {
                Text("No moves yet")
                    .font(Typography.callout.swiftUIFont)
                    .foregroundStyle(tokens.swiftUIColor(.textSecondary))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(entries) { entry in
                            Text(entry.text)
                                .font(Typography.callout.swiftUIFont)
                                .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            tokens.swiftUIColor(.surface)
                .opacity(backdropOpacity(reduceTransparency: reduceTransparency, translucent: 0.96))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tokens.swiftUIColor(.separator))
                .frame(width: 1)
        }
        .accessibilityLabel(Text("Move history"))
    }
}

// MARK: - Pause menu (R-TABLE-6.1)

/// The pause menu: a modal-style overlay of pause actions (R-TABLE-6.1). A pure function of a
/// `[PauseMenuItem]` list plus a selection callback.
public struct PauseMenuView: View {
    private let items: [PauseMenuItem]
    private let onSelect: (PauseMenuItem) -> Void

    @Environment(\.designTokens) private var tokens

    public init(
        items: [PauseMenuItem] = PauseMenuItem.standard,
        onSelect: @escaping (PauseMenuItem) -> Void = { _ in }
    ) {
        self.items = items
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack {
            // A dimming scrim; tapping it resumes (the least-destructive action).
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onSelect(.resume) }
                .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Paused")
                    .font(Typography.title2.swiftUIFont)
                    .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                    .padding(.bottom, Spacing.xs)
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: item.systemImage)
                                .frame(width: 20)
                            Text(item.title)
                                .font(Typography.body.swiftUIFont)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tokens.swiftUIColor(.textPrimary))
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(tokens.swiftUIColor(.surface))
                    )
                }
            }
            .padding(Spacing.lg)
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .fill(tokens.swiftUIColor(.surfaceElevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .strokeBorder(tokens.swiftUIColor(.controlBorder).opacity(0.5), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(Elevation.high.opacity),
                radius: Elevation.high.radius,
                y: Elevation.high.offsetY)
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Toolbar (R-TABLE-6.1)

/// The table toolbar: New, Undo, Hint, Rules, Menu (R-TABLE-6.1). A pure function of the enabled-actions
/// set plus a selection callback; Undo/Hint disable when unavailable.
public struct TableToolbarView: View {
    private let enabled: Set<ToolbarAction>
    private let onSelect: (ToolbarAction) -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.reduceTransparency) private var reduceTransparency

    /// Create the toolbar.
    ///
    /// - Parameters:
    ///   - enabled: which actions are currently enabled; actions absent from the set render disabled.
    ///     Defaults to all enabled.
    ///   - onSelect: invoked with the tapped action.
    public init(
        enabled: Set<ToolbarAction> = Set(ToolbarAction.allCases),
        onSelect: @escaping (ToolbarAction) -> Void = { _ in }
    ) {
        self.enabled = enabled
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(ToolbarAction.allCases) { action in
                let isEnabled = enabled.contains(action)
                Button {
                    onSelect(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(Typography.callout.swiftUIFont)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isEnabled
                        ? tokens.swiftUIColor(.textPrimary)
                        : tokens.swiftUIColor(.textSecondary).opacity(0.5)
                )
                .disabled(!isEnabled)
                .accessibilityLabel(Text(action.title))
                .accessibilityHint(Text(action.accessibilityHint))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            Capsule().fill(
                tokens.swiftUIColor(.surfaceElevated)
                    .opacity(
                        backdropOpacity(reduceTransparency: reduceTransparency, translucent: 0.94))
            )
        )
        .overlay(
            Capsule().strokeBorder(tokens.swiftUIColor(.controlBorder).opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Composing HUD (R-TABLE-6.1, 6.2, 6.3)

/// The complete table HUD, laid over the felt in the reserved edge chrome regions so it never covers the
/// cards a player needs (R-TABLE-6.1, R-TABLE-6.2, R-TABLE-6.3).
///
/// It positions seat plates at the `SeatArrangement` anchors (local player bottom-center, others
/// clockwise), puts the scoreboard + caption in the top band, the toolbar in the bottom band, the history
/// drawer in the right rail (when open), and overlays the pause menu (when shown). The `HUDLayout`
/// (computed purely) is the single source of the region geometry, so the same insets a game feeds its
/// `TableLayout` keep the play zones clear of this chrome.
public struct TableHUDView: View {
    private let plates: [SeatPlateState]
    private let scoreboard: ScoreboardModel
    private let caption: String?
    private let history: [HistoryEntry]
    private let historyOpen: Bool
    private let enabledToolbarActions: Set<ToolbarAction>
    private let seating: SeatArrangement
    private let onToolbar: (ToolbarAction) -> Void
    private let onCloseHistory: () -> Void

    /// Create the composed HUD.
    public init(
        plates: [SeatPlateState],
        scoreboard: ScoreboardModel,
        caption: String? = nil,
        history: [HistoryEntry] = [],
        historyOpen: Bool = false,
        enabledToolbarActions: Set<ToolbarAction> = Set(ToolbarAction.allCases),
        seating: SeatArrangement = SeatArrangement(),
        onToolbar: @escaping (ToolbarAction) -> Void = { _ in },
        onCloseHistory: @escaping () -> Void = {}
    ) {
        self.plates = plates
        self.scoreboard = scoreboard
        self.caption = caption
        self.history = history
        self.historyOpen = historyOpen
        self.enabledToolbarActions = enabledToolbarActions
        self.seating = seating
        self.onToolbar = onToolbar
        self.onCloseHistory = onCloseHistory
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = HUDLayout.standard(historyOpen: historyOpen)

            ZStack(alignment: .topLeading) {
                // Seat plates at their seat-ring anchors (local bottom-center, others clockwise).
                ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                    let anchor = seating.anchor(seatIndex: index, count: max(1, plates.count))
                    SeatPlateView(state: plate)
                        .fixedSize()
                        .position(x: anchor.x * size.width, y: anchor.y * size.height)
                }

                // Top band: scoreboard (leading) + caption (centered).
                ScoreboardView(model: scoreboard)
                    .fixedSize()
                    .padding(.leading, Spacing.lg)
                    .position(
                        x: topBandLeadingX(size), y: layout.topBand.center.y * size.height)

                if let caption {
                    CaptionBarView(caption)
                        .position(
                            x: size.width / 2, y: layout.topBand.center.y * size.height)
                }

                // Bottom band: toolbar centered.
                TableToolbarView(enabled: enabledToolbarActions, onSelect: onToolbar)
                    .position(
                        x: size.width / 2, y: layout.bottomBand.center.y * size.height)

                // Right rail: history drawer when open.
                if historyOpen {
                    HistoryDrawerView(entries: history, onClose: onCloseHistory)
                        .frame(
                            width: layout.rightRail.width * size.width,
                            height: layout.rightRail.height * size.height
                        )
                        .position(
                            x: layout.rightRail.center.x * size.width,
                            y: layout.rightRail.center.y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    /// Keep the scoreboard hugging the left edge without running off it at small sizes.
    private func topBandLeadingX(_ size: CGSize) -> CGFloat {
        min(size.width * 0.18, 160)
    }
}
