import SwiftUI

// MARK: - MagneticSpotlightModifier
//
// Adds a premium, physically-based hover effect to buttons. Instead of
// flat color changes, a soft glowing radial gradient tracks the user's
// mouse cursor inside the boundaries of the shape, illuminating it like
// a frosted glass button reacting to a spotlight.

struct MagneticSpotlightModifier<S: InsettableShape>: ViewModifier {

    var active: Bool
    var baseOpacity: Double
    var activeOpacity: Double
    var shape: S

    @State private var hoverLocation: CGPoint? = nil

    func body(content: Content) -> some View {
        content
            .background(
                shape.fill(
                    active ? Color.white.opacity(activeOpacity) : Color.white.opacity(baseOpacity)
                )
            )
            .overlay(
                GeometryReader { geo in
                    if let location = hoverLocation {
                        shape
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color.white.opacity(0.35),
                                        Color.clear
                                    ]),
                                    center: UnitPoint(
                                        x: location.x / geo.size.width,
                                        y: location.y / geo.size.height
                                    ),
                                    startRadius: 0,
                                    endRadius: max(geo.size.width, geo.size.height) * 0.7
                                )
                            )
                            .blendMode(.plusLighter)
                    }
                }
            )
            // Stroke border
            .overlay(
                shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.8, blendDuration: 0.1)) {
                        hoverLocation = location
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.2)) {
                        hoverLocation = nil
                    }
                }
            }
    }
}

extension View {
    func magneticSpotlight<S: InsettableShape>(
        active: Bool = false,
        baseOpacity: Double = 0.08,
        activeOpacity: Double = 0.22,
        shape: S = Capsule()
    ) -> some View {
        self.modifier(MagneticSpotlightModifier(
            active: active,
            baseOpacity: baseOpacity,
            activeOpacity: activeOpacity,
            shape: shape
        ))
    }
}
