import SwiftUI
import Combine

// MARK: - AuraBackgroundView
//
// A SwiftUI view that renders a soft, animated, multi-color radial glow
// behind the Now Playing section. It reads the current album palette from
// PopoverPaletteSync (via NotificationCenter) and smoothly crossfades
// between palettes when the track changes.
//
// The effect: 2–3 overlapping radial gradients that drift slowly,
// creating a lava-lamp "color bleed" that makes each song feel unique.

struct AuraBackgroundView: View {

    @StateObject private var palette = AuraPaletteObserver()

    // Slow drift animation — keeps the aura alive without being distracting
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate * 0.15

                let colors = palette.colors
                guard colors.count >= 3 else { return }

                // ── Blob 1: large, dominant color, drifts upper-left → center ──
                let cx1 = size.width  * (0.25 + 0.20 * CGFloat(sin(t * 0.7)))
                let cy1 = size.height * (0.30 + 0.15 * CGFloat(cos(t * 0.5)))
                let r1  = max(size.width, size.height) * 0.7

                let grad1 = Gradient(colors: [
                    colors[0].opacity(0.55),
                    colors[0].opacity(0.0)
                ])
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: cx1 - r1/2, y: cy1 - r1/2,
                        width: r1, height: r1
                    )),
                    with: .radialGradient(
                        grad1,
                        center: CGPoint(x: cx1, y: cy1),
                        startRadius: 0,
                        endRadius: r1 * 0.5
                    )
                )

                // ── Blob 2: accent color, drifts lower-right ──
                let cx2 = size.width  * (0.70 + 0.15 * CGFloat(cos(t * 0.6 + 1.2)))
                let cy2 = size.height * (0.65 + 0.20 * CGFloat(sin(t * 0.8 + 0.8)))
                let r2  = max(size.width, size.height) * 0.55

                let grad2 = Gradient(colors: [
                    colors[1].opacity(0.45),
                    colors[1].opacity(0.0)
                ])
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: cx2 - r2/2, y: cy2 - r2/2,
                        width: r2, height: r2
                    )),
                    with: .radialGradient(
                        grad2,
                        center: CGPoint(x: cx2, y: cy2),
                        startRadius: 0,
                        endRadius: r2 * 0.5
                    )
                )

                // ── Blob 3: third color, drifts center-bottom ──
                let cx3 = size.width  * (0.45 + 0.18 * CGFloat(sin(t * 0.9 + 2.5)))
                let cy3 = size.height * (0.50 + 0.12 * CGFloat(cos(t * 0.55 + 1.8)))
                let r3  = max(size.width, size.height) * 0.45

                let grad3 = Gradient(colors: [
                    colors[2].opacity(0.35),
                    colors[2].opacity(0.0)
                ])
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: cx3 - r3/2, y: cy3 - r3/2,
                        width: r3, height: r3
                    )),
                    with: .radialGradient(
                        grad3,
                        center: CGPoint(x: cx3, y: cy3),
                        startRadius: 0,
                        endRadius: r3 * 0.5
                    )
                )
            }
        }
        .blur(radius: 24)           // heavy blur — soft organic glow, not blobs
        .opacity(palette.intensity)  // fades in when a track plays
        .allowsHitTesting(false)     // passthrough — doesn't eat clicks
    }
}

// MARK: - AuraPaletteObserver
//
// Bridges NotificationCenter → SwiftUI @Published so AuraBackgroundView
// reactively updates when PopoverPaletteSync pushes a new album palette.

final class AuraPaletteObserver: ObservableObject {

    @Published var colors: [Color] = AuraPaletteObserver.defaultColors
    @Published var intensity: Double = 0.0

    private var observer: NSObjectProtocol?

    init() {
        // Seed from current palette if one exists
        let current = PopoverPaletteSync.shared.currentColors
        if !current.isEmpty {
            colors = current.prefix(5).map { Color(nsColor: $0) }
            intensity = 1.0
        }

        observer = NotificationCenter.default.addObserver(
            forName: .popoverPaletteDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let nsColors = note.object as? [NSColor],
                  nsColors.count >= 3
            else { return }

            withAnimation(.easeInOut(duration: 1.2)) {
                self.colors = nsColors.prefix(5).map { Color(nsColor: $0) }
                self.intensity = 1.0
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static let defaultColors: [Color] = [
        Color(red: 0.55, green: 0.08, blue: 0.02),
        Color(red: 0.80, green: 0.22, blue: 0.02),
        Color(red: 0.25, green: 0.04, blue: 0.04),
        Color(red: 0.65, green: 0.15, blue: 0.01),
        Color(red: 0.12, green: 0.02, blue: 0.02),
    ]
}
