// CrazyEightsTableScreen — the real multiplayer-ready Crazy Eights table surface.

import DesignSystem
import GamesUI
import SwiftUI
import TableKit

struct CrazyEightsTableScreen: View {
    @State private var model: CrazyEightsTableViewModel
    @State private var showMenu = false

    @Environment(\.accessibilityReduceMotion) private var osReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var osReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(model: CrazyEightsTableViewModel) {
        _model = State(initialValue: model)
    }

    private var effective: EffectiveAccessibility {
        model.settings.effectiveAccessibility(
            osReduceMotion: osReduceMotion,
            osReduceTransparency: osReduceTransparency,
            osIncreaseContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        ZStack {
            TableSurface(theme: model.preferredTheme)
                .ignoresSafeArea()

            TableInteractionView(
                model: model.driver.model,
                layout: model.layout,
                input: model.interactionInput,
                zoneOrder: model.zoneOrder,
                resolver: LayoutResolver(cardSizeScale: model.cardSizeScale),
                seatCount: model.latestState.seatCount,
                seatIndexForOwner: { model.seatIndex(for: $0) },
                handZones: [CrazyEightsZone.hand(0)],
                animationSettings: model.driver.settings,
                faceContent: model.faceContent
            )

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crazy Eights")
                            .font(.title2.weight(.semibold))
                        Text(model.statusText)
                            .font(.callout)
                            .accessibilityIdentifier(
                                model.isAIThinking ? "crazy.ai.thinking" : "crazy.turn.status")
                    }
                    Spacer()
                    Text(
                        "Theme: \(model.preferredTheme.displayName) · Deck: \(model.preferredDeckStyle.displayName)"
                    )
                    .font(.caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Theme: \(model.preferredTheme.displayName) · Deck: \(model.preferredDeckStyle.displayName)"
                    )
                    .accessibilityIdentifier("crazy.appearance.status")
                    Button {
                        showMenu = true
                    } label: {
                        Label("Menu", systemImage: "pause.circle")
                    }
                    .accessibilityIdentifier("crazy.menu")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .allowsHitTesting(true)

                Spacer()

                if !model.localActions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.localActions, id: \.self) { action in
                                Button(model.actionLabel(action)) {
                                    model.play(action)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier(model.actionIdentifier(action))
                                .disabled(model.isSubmitting)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 18)
                }
            }

            if model.isHandComplete {
                VStack(spacing: 8) {
                    Text("Hand complete")
                        .font(.title.weight(.bold))
                    Text("Crazy Eights hand complete")
                        .font(.callout)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("crazy.hand.complete")
            }

            if showMenu {
                pauseMenu
            }
        }
        .id(model.uiRevision)
        .accessibilityIdentifier("table.screen")
        .tableDeckStyle(effective.deckStyle(preferred: model.preferredDeckStyle))
        .cardAppearance(effective.cardAppearance)
        .reduceTransparency(effective.reduceTransparency)
        .onAppear {
            model.driver.settings.reduceMotion = effective.reduceMotion
            model.startAIIfNeeded()
        }
        .onChange(of: osReduceMotion) {
            model.driver.settings.reduceMotion = effective.reduceMotion
        }
        .navigationTitle(model.gameTitle)
    }

    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showMenu = false }
            VStack(spacing: 10) {
                Text("Paused").font(.title2.weight(.semibold))
                Button("Resume") { showMenu = false }
                Button("Quit to Library") {
                    showMenu = false
                    model.quitToLibrary()
                }
                .accessibilityIdentifier("crazy.quitToLibrary")
            }
            .padding(24)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityAddTraits(.isModal)
    }
}
