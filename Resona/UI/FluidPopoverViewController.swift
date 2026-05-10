import AppKit
import SwiftUI

// MARK: - FluidPopoverViewController
//
// Custom NSViewController used as the popover's contentViewController.
// Layer stack (bottom → top):
//
//   ┌─────────────────────────────────────┐
//   │  4. SwiftUI content (MenuBarView)   │  ← full size, transparent bg
//   │  3. Noise grain overlay (CALayer)   │  ← adds film texture
//   │  2. NSVisualEffectView (ultraDark)  │  ← frosted glass + blur
//   │  1. PopoverFluidBackground (Metal)  │  ← live fluid shader
//   └─────────────────────────────────────┘
//
// The NSVisualEffectView uses .behindWindow so it composites the Metal layer
// beneath it (not the desktop behind the window), giving a "liquid glass"
// effect that blurs + tints the fluid colours rather than the wallpaper.

final class FluidPopoverViewController: NSViewController {

    // MARK: - Dependencies

    private let detectionService: MusicDetectionService
    private var fluidView: PopoverFluidBackground?

    // MARK: - Init

    init(detectionService: MusicDetectionService) {
        self.detectionService = detectionService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: CGSize(width: 300, height: 400)))
        container.wantsLayer = true

        // Rounded corners for the whole popover
        container.layer?.cornerRadius   = 16
        container.layer?.masksToBounds  = true

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayerStack()
        if let fluid = fluidView {
            PopoverPaletteSync.shared.register(fluid)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Animate in: fluid fades up from slightly below
        view.alphaValue = 0
        view.frame.origin.y -= 6
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
            view.animator().frame.origin.y += 6
        }
    }

    // MARK: - Layer stack construction

    private func buildLayerStack() {
        let bounds = view.bounds

        // ── Layer 1: Metal fluid background ──────────────────────────────
        if let fluid = PopoverFluidBackground.make(frame: bounds) {
            fluid.autoresizingMask = [.width, .height]
            view.addSubview(fluid)
            fluidView = fluid
        } else {
            // Metal unavailable — fall back to a dark solid
            let fallback = NSView(frame: bounds)
            fallback.wantsLayer = true
            fallback.layer?.backgroundColor = NSColor(red: 0.08, green: 0.02, blue: 0.02, alpha: 1).cgColor
            fallback.autoresizingMask = [.width, .height]
            view.addSubview(fallback)
        }

        // ── Layer 2: Visual effect (glass + blur over the Metal layer) ───
        let glass = NSVisualEffectView(frame: bounds)
        glass.material       = .hudWindow          // dark frosted glass
        glass.blendingMode   = .withinWindow       // blurs what's behind IT inside the window
        glass.state          = .active
        glass.alphaValue     = 0.55                // partial — lets fluid colour bleed through
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass)

        // ── Layer 3: Noise grain overlay ──────────────────────────────────
        let grain = GrainLayer(bounds: bounds)
        grain.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(grain)

        // ── Layer 4: SwiftUI content ──────────────────────────────────────
        let content = NSHostingView(
            rootView: MenuBarView(detectionService: detectionService)
                .background(Color.clear)           // transparent — fluid shows through
        )
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        // Make the hosting view's layer transparent
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(content)

        // ── Subtle border ring ────────────────────────────────────────────
        let border = CALayer()
        border.frame              = bounds
        border.cornerRadius       = 16
        border.borderWidth        = 0.75
        border.borderColor        = NSColor.white.withAlphaComponent(0.18).cgColor
        border.backgroundColor    = NSColor.clear.cgColor
        border.autoresizingMask   = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(border)
    }
}

// MARK: - GrainLayer
//
// A CALayer that tiles a procedural noise texture to add a subtle film grain
// effect, breaking up the smooth gradient and giving the glass a tactile feel.

private final class GrainLayer: CALayer {

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError() }

    init(bounds: CGRect) {
        super.init()
        frame            = bounds
        opacity          = 0.045   // very subtle — just enough texture
        isOpaque         = false
        backgroundColor  = NSColor.clear.cgColor
        contents         = makeGrainImage(size: CGSize(width: 128, height: 128))
        contentsGravity  = .resize
        // Animate the grain by slowly shifting the phase — makes it feel alive
        let anim         = CABasicAnimation(keyPath: "contentsRect.origin.x")
        anim.fromValue   = 0.0
        anim.toValue     = 1.0
        anim.duration    = 8.0
        anim.repeatCount = .infinity
        add(anim, forKey: "grainDrift")
    }

    private func makeGrainImage(size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        // Simple XOR noise — fast, no dependencies
        var seed: UInt32 = 0xDEADBEEF
        for i in 0..<(w * h) {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            let v = UInt8(seed & 0xFF)
            pixels[i*4+0] = v
            pixels[i*4+1] = v
            pixels[i*4+2] = v
            pixels[i*4+3] = 255
        }

        let cs  = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return ctx.makeImage()
    }
}

// MARK: - MenuBarView background override
//
// The existing MenuBarView uses .ultraThinMaterial as its background.
// We inject a transparent modifier so the fluid+glass stack shows through.
// This is done via a ViewModifier so MenuBarView.swift needs minimal changes.

extension View {
    /// Strips any opaque background so the fluid popover layer shows through.
    func fluidPopoverContent() -> some View {
        self.background(Color.clear)
    }
}
