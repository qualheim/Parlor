// CardFaceCache — rasterizes each vector face/back once per key and reuses it (R-TABLE-2.1).
//
// R-TABLE-2.1 requires card views to use CACHED vector faces/backs keyed by (theme, face, scale,
// appearance), never redrawn every frame. `CardFaceCache` is that cache: given a `CardFaceKey` and the
// catalogs to draw from, it rasterizes the `CardFaceCanvas` vector to an `Image` exactly once and stores
// it keyed by the `CardFaceKey`. Every subsequent request for the same key returns the stored image, so a
// card that is hovered, lifted, flipped, or animated is composited from a cached bitmap — the vector is
// not re-drawn on those frames.
//
// The cache is a `Sendable` reference type guarded by a lock, so it can be a nonisolated SwiftUI
// environment value (the accessors are nonisolated). Only the rasterizing `image(...)` method is
// `@MainActor`, because `ImageRenderer` (the vector→image rasterizer) is main-actor-only. A single
// instance is shared through the environment so every card view on a table hits the same cache.

import DesignSystem
import Foundation
import SwiftUI

/// A keyed cache of rasterized card faces/backs (R-TABLE-2.1). One instance per table scene, shared via
/// the environment. Rasterizes on a miss; returns the stored image on a hit — never redraws per frame.
///
/// `Sendable` and internally locked so it can serve as a nonisolated environment default; the only
/// main-actor-bound operation is `image(...)`, which drives the main-actor `ImageRenderer`.
public final class CardFaceCache: Sendable {
    private struct State {
        var images: [CardFaceKey: Image] = [:]
        var missCount = 0
        var hitCount = 0
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var state = State()

    public init() {}

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// The cached `Image` for `key`, rasterizing the vector `CardFaceCanvas` on a miss and storing it.
    ///
    /// `size` is the point size to rasterize at; the key's `scaleBucket` already quantizes size so nearby
    /// sizes share one image. `displayScale` is the device pixel scale the image is rendered for.
    /// `@MainActor` because `ImageRenderer` is main-actor-only.
    @MainActor
    public func image(
        for key: CardFaceKey,
        style: DeckStyle,
        back: CardBack,
        theme: TableTheme,
        size: CGSize,
        displayScale: CGFloat
    ) -> Image {
        if let cached = withState({ $0.images[key] }) {
            withState { $0.hitCount += 1 }
            return cached
        }
        let canvas = CardFaceCanvas(key: key, style: style, back: back, theme: theme, size: size)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = displayScale
        let image: Image
        if let cg = renderer.cgImage {
            image = Image(decorative: cg, scale: displayScale, orientation: .up)
        } else {
            // Extremely defensive fallback: if rasterization is unavailable (e.g. a headless environment),
            // fall back to drawing the vector view directly. The key still governs identity.
            image = Image(size: size) { ctx in
                ctx.fill(
                    RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.1).path(
                        in: CGRect(origin: .zero, size: size)), with: .color(.white))
            }
        }
        withState {
            $0.images[key] = image
            $0.missCount += 1
        }
        return image
    }

    /// Whether an image for `key` is already cached (a hit would not re-rasterize). For tests/overlay.
    public func isCached(_ key: CardFaceKey) -> Bool { withState { $0.images[key] != nil } }

    /// The number of distinct cached images.
    public var count: Int { withState { $0.images.count } }

    /// The number of cache misses (rasterizations) so far — for tests and the debug overlay.
    public var missCount: Int { withState { $0.missCount } }

    /// The number of cache hits so far — for tests and the debug overlay.
    public var hitCount: Int { withState { $0.hitCount } }

    /// Drop all cached images (e.g. on a memory warning). Keys re-rasterize lazily on next request.
    public func clear() {
        withState {
            $0.images.removeAll()
            $0.missCount = 0
            $0.hitCount = 0
        }
    }
}

// MARK: - Environment plumbing

private struct CardFaceCacheKey: EnvironmentKey {
    static let defaultValue = CardFaceCache()
}

extension EnvironmentValues {
    /// The shared per-scene card-face cache. Card views read it to fetch cached vector faces/backs
    /// (R-TABLE-2.1). The table scene injects one instance; the default is a process-wide fallback.
    public var cardFaceCache: CardFaceCache {
        get { self[CardFaceCacheKey.self] }
        set { self[CardFaceCacheKey.self] = newValue }
    }
}

extension View {
    /// Inject a shared `CardFaceCache` for this subtree so all card views share one keyed cache.
    public func cardFaceCache(_ cache: CardFaceCache) -> some View {
        environment(\.cardFaceCache, cache)
    }
}
