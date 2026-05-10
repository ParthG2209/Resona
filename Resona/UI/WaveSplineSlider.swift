import SwiftUI

// MARK: - WaveSplineSlider
//
// A custom slider that replaces the standard macOS Slider for wave intensity.
// Instead of a flat track + knob, the "track" IS a live animated waveform:
//
//   value = 0.0  →  flat horizontal line  ("Still")
//   value = 0.5  →  gentle rolling sine   ("Moderate")
//   value = 1.0  →  aggressive jagged peaks ("Intense")
//
// The waveform animates continuously via TimelineView so it feels alive,
// and the amplitude/frequency morph smoothly as the user drags.
//
// Interaction: horizontal drag anywhere on the view adjusts the value.
// A subtle glowing handle sits at the current position on the wave.

struct WaveSplineSlider: View {

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.05

    // Internal drag state
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate

                Canvas { context, size in
                    drawWave(context: context, size: size, time: time)
                    drawHandle(context: context, size: size, time: time)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let fraction = Double(drag.location.x / geo.size.width)
                        let clamped  = min(max(fraction, 0), 1)
                        let raw      = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                        value = (raw / step).rounded() * step
                        value = min(max(value, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.3)) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: 32)
    }

    // MARK: - Wave Drawing

    private func drawWave(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let w = size.width
        let h = size.height
        let midY = h / 2.0

        // Normalize value to 0...1
        let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

        // Amplitude scales with value — 0 = flat, 1 = tall peaks
        let maxAmp = h * 0.38
        let amplitude = maxAmp * CGFloat(t)

        // Frequency increases with value — more peaks at higher intensity
        let baseFreq: CGFloat = 2.0
        let freq = baseFreq + CGFloat(t) * 4.0

        // Animation speed scales with intensity
        let speed = 0.4 + t * 1.8

        // Build the wave path
        var path = Path()
        let steps = Int(w / 1.5) // ~1 point per 1.5px for smooth curves

        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * w
            let phase = CGFloat(time * speed)

            // Composite of two sine waves for organic feel
            let wave1 = sin((x / w) * .pi * 2.0 * freq + phase * 3.0)
            let wave2 = sin((x / w) * .pi * 2.0 * (freq * 0.6) + phase * 2.1 + 0.7)

            // Mix: primary wave + harmonic for complexity
            let combined = wave1 * 0.7 + wave2 * 0.3

            // Add some "jag" at high intensities by mixing in a sharper function
            let jag = CGFloat(t) > 0.6
                ? sin((x / w) * .pi * 2.0 * freq * 2.5 + phase * 4.0) * CGFloat((t - 0.6) / 0.4) * 0.4
                : 0.0

            let y = midY + (combined + jag) * amplitude

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        // Stroke the wave with a gradient that's brighter at the handle position
        let glowColor = Color.white.opacity(isDragging ? 0.9 : 0.6)
        let dimColor  = Color.white.opacity(isDragging ? 0.35 : 0.2)

        // Create a gradient that brightens near the handle
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: dimColor, location: 0),
                    .init(color: glowColor, location: max(0, CGFloat(t) - 0.15)),
                    .init(color: glowColor, location: CGFloat(t)),
                    .init(color: dimColor, location: min(1, CGFloat(t) + 0.15)),
                    .init(color: dimColor, location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: w, y: midY)
            ),
            style: StrokeStyle(lineWidth: isDragging ? 2.0 : 1.5, lineCap: .round, lineJoin: .round)
        )

        // Subtle filled region below the wave for depth
        var fillPath = path
        fillPath.addLine(to: CGPoint(x: w, y: h))
        fillPath.addLine(to: CGPoint(x: 0, y: h))
        fillPath.closeSubpath()

        context.fill(
            fillPath,
            with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(isDragging ? 0.08 : 0.04),
                    Color.white.opacity(0.0),
                ]),
                startPoint: CGPoint(x: w / 2, y: midY - amplitude),
                endPoint: CGPoint(x: w / 2, y: h)
            )
        )
    }

    // MARK: - Handle Drawing

    private func drawHandle(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let w = size.width
        let h = size.height
        let midY = h / 2.0

        let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let handleX = w * CGFloat(t)

        // Calculate the wave Y at the handle position
        let maxAmp = h * 0.38
        let amplitude = maxAmp * CGFloat(t)
        let freq = 2.0 + CGFloat(t) * 4.0
        let speed = 0.4 + t * 1.8
        let phase = CGFloat(time * speed)

        let wave1 = sin((CGFloat(t)) * .pi * 2.0 * freq + phase * 3.0)
        let wave2 = sin((CGFloat(t)) * .pi * 2.0 * (freq * 0.6) + phase * 2.1 + 0.7)
        let combined = wave1 * 0.7 + wave2 * 0.3
        let handleY = midY + combined * amplitude

        let handleRadius: CGFloat = isDragging ? 5.5 : 4.0

        // Outer glow
        let glowRect = CGRect(
            x: handleX - handleRadius * 2.5,
            y: handleY - handleRadius * 2.5,
            width: handleRadius * 5,
            height: handleRadius * 5
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(isDragging ? 0.3 : 0.15),
                    Color.white.opacity(0.0),
                ]),
                center: CGPoint(x: handleX, y: handleY),
                startRadius: 0,
                endRadius: handleRadius * 2.5
            )
        )

        // Handle dot
        let dotRect = CGRect(
            x: handleX - handleRadius,
            y: handleY - handleRadius,
            width: handleRadius * 2,
            height: handleRadius * 2
        )
        context.fill(
            Path(ellipseIn: dotRect),
            with: .color(Color.white)
        )

        // Inner bright core
        let coreRadius = handleRadius * 0.4
        let coreRect = CGRect(
            x: handleX - coreRadius,
            y: handleY - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .color(Color.white.opacity(0.9))
        )
    }


}

// MARK: - Preview

#if DEBUG
struct WaveSplineSlider_Preview: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            WaveSplineSlider(value: .constant(0.0))
            WaveSplineSlider(value: .constant(0.3))
            WaveSplineSlider(value: .constant(0.7))
            WaveSplineSlider(value: .constant(1.0))
        }
        .padding()
        .background(Color.black)
    }
}
#endif
