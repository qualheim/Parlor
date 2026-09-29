// DebugOverlay — debug-only FPS + state-inspector overlay hook (R-NFR-QUAL.4).
//
// Debug builds include an on-screen FPS readout and a small state-inspector panel; release builds do
// NOT (R-NFR-QUAL.4, tech.md). The whole overlay is guarded by `#if DEBUG`, and the public seam —
// `View.debugOverlay(_:)` — compiles to a no-op that returns `self` unchanged in release builds, so
// there is zero overhead and no attack surface in shipping binaries.
//
// This is the foundation-stage *hook*: the FPS meter is real, and the inspector renders whatever
// key/value lines a caller hands it. Later phases (the table renderer, GameHost) feed it live state
// such as animation-queue depth or the current match hash; nothing here needs to change for that.

import SwiftUI

extension View {
    /// Overlays the debug FPS + state-inspector panel in debug builds; a no-op in release builds.
    ///
    /// - Parameter state: Key/value lines to show in the inspector. Evaluated lazily (an autoclosure)
    ///   so callers pay nothing to build the snapshot in release builds, where the overlay is compiled
    ///   out entirely.
    /// - Returns: The view, with the overlay attached in debug builds.
    func debugOverlay(_ state: @autoclosure @escaping () -> [DebugInspectorLine] = []) -> some View
    {
        #if DEBUG
            return overlay(alignment: .topTrailing) {
                DebugOverlayView(state: state)
            }
        #else
            return self
        #endif
    }
}

/// One labelled line in the debug state inspector (e.g. `label: "fps"`, `value: "60"`).
struct DebugInspectorLine: Identifiable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

#if DEBUG

    /// The debug overlay: a live FPS readout plus a compact state-inspector panel. Present only in
    /// debug builds (R-NFR-QUAL.4).
    struct DebugOverlayView: View {
        /// Lazily-evaluated inspector snapshot supplied by the host view.
        let state: () -> [DebugInspectorLine]

        var body: some View {
            TimelineView(.animation) { context in
                VStack(alignment: .leading, spacing: 2) {
                    FPSReadout(date: context.date)
                    ForEach(state()) { line in
                        Text("\(line.label): \(line.value)")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
                .padding(6)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 6))
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Estimates frames per second from the timeline's frame timestamps and renders the value.
    ///
    /// `TimelineView(.animation)` ticks once per displayed frame, so the gap between successive dates
    /// is one frame's duration; its reciprocal is the instantaneous FPS. A short rolling average keeps
    /// the number readable instead of jittering every frame.
    private struct FPSReadout: View {
        let date: Date

        @State private var lastDate: Date?
        @State private var smoothedFPS: Double = 0

        var body: some View {
            Text("fps: \(Int(smoothedFPS.rounded()))")
                .onChange(of: date) { _, newDate in
                    guard let previous = lastDate else {
                        lastDate = newDate
                        return
                    }
                    let delta = newDate.timeIntervalSince(previous)
                    lastDate = newDate
                    guard delta > 0 else { return }
                    let instantaneous = 1.0 / delta
                    // Exponential moving average smooths per-frame jitter.
                    smoothedFPS =
                        smoothedFPS == 0 ? instantaneous : smoothedFPS * 0.9 + instantaneous * 0.1
                    AppLog.diagnostics.trace(
                        "fps sample: \(instantaneous, format: .fixed(precision: 1))")
                }
        }
    }

#endif
