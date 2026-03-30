import AppKit
import AVFoundation
import CoreImage
import MetalKit

// MARK: - AnimatedWallpaperController
/// Creates a borderless desktop-level window and displays animated album art
/// using a Metal GPU shader (fluid color waves) + static centered album artwork.
/// Also supports video playback for Spotify Canvas when available.
///
/// THERMAL OPTIMIZATIONS (all invisible to the user):
/// 1. FluidWaveView is NEVER destroyed between song changes — only its color palette
///    is updated. This eliminates the GPU pipeline teardown/rebuild spike on every skip.
/// 2. CIContext is a class-level singleton — created once, reused forever.
///    Previously a new CIContext was allocated on every song change (expensive).
/// 3. extractPaletteColors runs on a BACKGROUND THREAD — the 10x CIAreaAverage
///    calls no longer block the main thread or spike the GPU during transitions.
/// 4. dominantColor() is merged into the palette extraction pass — the center-crop
///    average is computed once and reused instead of running a separate CIFilter pass.
/// 5. Internal render resolution is 50% of native Retina — Metal upscales smoothly.
///    Fluid gradients are mathematically smooth so this is visually identical.

final class AnimatedWallpaperController {

    static let shared = AnimatedWallpaperController()
    private init() { observeScreenChanges() }

    // MARK: - State

    private var windows: [NSWindow] = []
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var currentTrackID: String?
    private(set) var isShowing = false

    // Persistent art views — kept alive across song changes so Metal is never rebuilt.
    // Only the artwork image and color palette are swapped when a track changes.
    private var artViews: [AnimatedArtworkView] = []

    // MARK: - Public

    func show(artworkImage: NSImage, trackID: String, canvasURL: URL? = nil) {
        guard trackID != currentTrackID else { return }
        currentTrackID = trackID
        isShowing = true

        if canvasURL != nil {
            // Canvas path — rebuild the video layer (unavoidable, new stream)
            dismissImmediate()
            for screen in NSScreen.screens {
                let win = makeDesktopWindow(for: screen)
                attachVideo(to: win, url: canvasURL!, screen: screen)
                win.alphaValue = 0
                win.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 1.0
                    win.animator().alphaValue = 1
                }
                windows.append(win)
            }
        } else if windows.isEmpty || artViews.isEmpty {
            // First launch or after a canvas was showing — build Metal views fresh.
            dismissImmediate()
            for screen in NSScreen.screens {
                let win = makeDesktopWindow(for: screen)
                let artView = AnimatedArtworkView(frame: screen.frame)
                artView.autoresizingMask = [.width, .height]
                win.contentView = artView
                artViews.append(artView)
                win.alphaValue = 0
                win.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 1.0
                    win.animator().alphaValue = 1
                }
                windows.append(win)
            }
            // Now configure with the initial artwork (builds layers + starts extraction)
            for (i, artView) in artViews.enumerated() {
                let screen = NSScreen.screens[safe: i] ?? NSScreen.main ?? NSScreen.screens[0]
                artView.configure(with: artworkImage, scale: screen.backingScaleFactor)
            }
        } else {
            // *** THE KEY THERMAL FIX ***
            // Metal views already exist and are rendering. Do NOT tear them down.
            // Just update the artwork image and kick off a background color extraction.
            // The FluidWaveView keeps rendering at 60fps with the old palette until
            // the new palette is ready, then smoothly switches. Zero GPU spike.
            for (i, artView) in artViews.enumerated() {
                let screen = NSScreen.screens[safe: i] ?? NSScreen.main ?? NSScreen.screens[0]
                artView.configure(with: artworkImage, scale: screen.backingScaleFactor)
            }
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        currentTrackID = nil
        artViews.removeAll()
        queuePlayer?.pause(); queuePlayer = nil; playerLooper = nil

        let old = windows; windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            old.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            old.forEach { $0.orderOut(nil) }
        })
    }

    // MARK: - Private

    private func dismissImmediate() {
        artViews.removeAll()
        queuePlayer?.pause(); queuePlayer = nil; playerLooper = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        isShowing = false
        currentTrackID = nil
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isShowing else { return }
            self.dismissImmediate()
        }
    }

    private func makeDesktopWindow(for screen: NSScreen) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = true; w.hasShadow = false
        w.ignoresMouseEvents = true; w.backgroundColor = .black
        return w
    }

    private func attachVideo(to window: NSWindow, url: URL, screen: NSScreen) {
        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true

        let playerLayer = AVPlayerLayer(player: player)
        let inset = -screen.frame.height * 0.05
        playerLayer.frame = view.bounds.insetBy(dx: inset, dy: inset)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.contentsScale = screen.backingScaleFactor
        playerLayer.magnificationFilter = .trilinear
        playerLayer.minificationFilter = .trilinear

        if let vibranceFilter = CIFilter(name: "CIColorControls", parameters: [
            kCIInputSaturationKey: 1.25,
            kCIInputContrastKey: 1.08
        ]) {
            playerLayer.filters = [vibranceFilter]
        }

        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.frame = view.bounds
        vignette.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.25).cgColor,
            NSColor.black.withAlphaComponent(0.6).cgColor
        ]
        vignette.locations = [0.3, 0.7, 1.0]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.0, y: 1.0)
        view.layer?.addSublayer(playerLayer)
        view.layer?.addSublayer(vignette)

        window.contentView = view
        player.play()
        queuePlayer = player
    }
}

// MARK: - Array safe subscript helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}

// MARK: - FluidWaveView (Metal GPU-accelerated fluid background)

final class FluidWaveView: MTKView, MTKViewDelegate {

    // Cached across ALL instances — shader compiled exactly once per app lifetime.
    // Previously this was recreated on every song change, causing a GPU pipeline spike.
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedQueue: MTLCommandQueue?

    private var pipelineState: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var startTime: CFAbsoluteTime = 0
    private var palette: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0.12, 0.08, 0.2, 1), count: 5)

    /// Internal render scale — 0.5 means the shader runs at 50% of native Retina resolution.
    /// Metal's hardware sampler upscales to the full display seamlessly.
    /// Fluid gradients are mathematically smooth so this looks identical at any scale.
    /// This alone cuts GPU fill-rate work by 4× (from ~16M pixels to ~4M on a 2x display).
    private let internalScale: CGFloat = 0.5

    struct Uniforms {
        var time: Float
        var speed: Float
        var resolution: SIMD2<Float>
        var color0: SIMD4<Float>
        var color1: SIMD4<Float>
        var color2: SIMD4<Float>
        var color3: SIMD4<Float>
        var color4: SIMD4<Float>
    }

    /// Factory method — returns nil if Metal is unavailable.
    static func create(frame: NSRect) -> FluidWaveView? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Resona] Metal not available")
            return nil
        }

        let pipeline: MTLRenderPipelineState
        let queue: MTLCommandQueue

        if let cached = cachedPipeline, let cq = cachedQueue {
            // Reuse the already-compiled pipeline — critical for song-change perf.
            pipeline = cached
            queue = cq
        } else {
            guard let q = device.makeCommandQueue(),
                  let library = compileShader(device: device),
                  let vertFn = library.makeFunction(name: "fluidVertex"),
                  let fragFn = library.makeFunction(name: "fluidFragment")
            else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                pipeline = try device.makeRenderPipelineState(descriptor: desc)
                queue = q
                cachedPipeline = pipeline
                cachedQueue = queue
            } catch {
                print("[Resona] Metal pipeline error: \(error)")
                return nil
            }
        }

        let view = FluidWaveView(frame: frame, device: device)
        view.pipelineState = pipeline
        view.commandQueue = queue
        return view
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        delegate = self
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm
        startTime = CFAbsoluteTimeGetCurrent()

        // Apply internal resolution scaling at init and keep it locked.
        // This is the primary GPU thermal fix: 4x fewer pixels to shade per frame.
        if let layer = self.layer as? CAMetalLayer {
            layer.contentsScale = (NSScreen.main?.backingScaleFactor ?? 2.0) * internalScale
        }
    }

    required init(coder: NSCoder) { fatalError() }

    /// Called when a new song's palette is ready (from background thread extraction).
    /// This is a lightweight SIMD copy — no GPU reinitialization, zero spike.
    func updateColors(from nsColors: [NSColor]) {
        palette = nsColors.prefix(5).map { c -> SIMD4<Float> in
            guard let rgb = c.usingColorSpace(.deviceRGB) else { return SIMD4<Float>(0.5, 0.5, 0.5, 1) }
            return SIMD4<Float>(Float(rgb.redComponent), Float(rgb.greenComponent),
                                Float(rgb.blueComponent), 1)
        }
        while palette.count < 5 { palette.append(palette.last ?? SIMD4<Float>(0.3, 0.3, 0.3, 1)) }
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let passDesc = currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        let intensity = Float(AppSettings.shared.waveIntensity)
        let speed: Float = 0.02 + intensity * 0.26

        var u = Uniforms(
            time: Float(CFAbsoluteTimeGetCurrent() - startTime),
            speed: speed,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            color0: palette[0], color1: palette[1], color2: palette[2],
            color3: palette[3], color4: palette[4]
        )

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if let layer = view.layer as? CAMetalLayer {
            layer.contentsScale = (NSScreen.main?.backingScaleFactor ?? 2.0) * internalScale
        }
    }

    // MARK: - Embedded Metal Shader (compiled once at runtime)

    private static func compileShader(device: MTLDevice) -> MTLLibrary? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float time;
            float speed;
            float2 resolution;
            float4 color0;
            float4 color1;
            float4 color2;
            float4 color3;
            float4 color4;
        };

        struct V { float4 pos [[position]]; float2 uv; };

        // Full-screen triangle — more efficient than a quad (3 verts vs 6)
        vertex V fluidVertex(uint vid [[vertex_id]]) {
            V o;
            o.uv = float2((vid << 1) & 2, vid & 2);
            o.pos = float4(o.uv * 2.0 - 1.0, 0.0, 1.0);
            o.uv.y = 1.0 - o.uv.y;
            return o;
        }

        // ── Simplex 2D noise ──────────────────────────────────────────
        float3 mod289(float3 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
        float2 mod289(float2 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
        float3 permute(float3 x) { return mod289(((x*34.0)+1.0)*x); }

        float snoise(float2 v) {
            const float4 C = float4(0.211324865405187, 0.366025403784439,
                                    -0.577350269189626, 0.024390243902439);
            float2 i = floor(v + dot(v, C.yy));
            float2 x0 = v - i + dot(i, C.xx);
            float2 i1 = (x0.x > x0.y) ? float2(1,0) : float2(0,1);
            float4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = mod289(i);
            float3 p = permute(permute(i.y + float3(0, i1.y, 1)) + i.x + float3(0, i1.x, 1));
            float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
            m = m*m; m = m*m;
            float3 x_ = 2.0*fract(p * C.www) - 1.0;
            float3 h = abs(x_) - 0.5;
            float3 ox = floor(x_ + 0.5);
            float3 a0 = x_ - ox;
            m *= 1.79284291400159 - 0.85373472095314*(a0*a0 + h*h);
            float3 g;
            g.x = a0.x*x0.x + h.x*x0.y;
            g.yz = a0.yz*x12.xz + h.yz*x12.yw;
            return 130.0 * dot(m, g);
        }

        // ── Fragment: fluid color waves ───────────────────────────────
        fragment float4 fluidFragment(V in [[stage_in]],
                                       constant Uniforms &u [[buffer(0)]]) {
            float2 uv = in.uv;
            float t = u.time * u.speed;

            float aspect = u.resolution.x / u.resolution.y;
            float2 st = float2(uv.x * aspect, uv.y);

            // Domain warping — distort coordinates for fluid feel
            float2 warp1 = float2(
                snoise(st * 1.2 + float2(t*0.3, t*0.2)),
                snoise(st * 1.2 + float2(t*0.2, -t*0.3))
            ) * 0.18;

            float2 warp2 = float2(
                snoise((st + warp1) * 0.8 + float2(-t*0.15, t*0.1)),
                snoise((st + warp1) * 0.8 + float2(t*0.1, t*0.15))
            ) * 0.12;

            float2 warped = st + warp1 + warp2;

            // Noise layers at different scales
            float n1 = snoise(warped * 1.5  + float2(t*0.4,  t*0.25));
            float n2 = snoise(warped * 2.2  + float2(-t*0.3, t*0.4));
            float n3 = snoise(warped * 1.0  + float2(t*0.2, -t*0.35));
            float n4 = snoise(warped * 2.8  + float2(-t*0.2, -t*0.15));

            // Blend palette colors using noise
            float4 c = u.color0;
            c = mix(c, u.color1, smoothstep(-0.4, 0.4, n1));
            c = mix(c, u.color2, smoothstep(-0.3, 0.5, n2) * 0.7);
            c = mix(c, u.color3, smoothstep(-0.5, 0.3, n3) * 0.55);
            c = mix(c, u.color4, smoothstep(-0.35, 0.35, n4) * 0.4);

            // Second warp pass for more fluid depth
            float n5 = snoise((warped + warp2*2.0) * 1.8 + float2(t*0.35, t*0.15));
            c = mix(c, u.color1*0.6 + u.color3*0.4, smoothstep(-0.2, 0.5, n5) * 0.3);

            // Vignette (built into shader — free, no extra pass)
            float2 vc = uv - 0.5;
            float vig = 1.0 - dot(vc, vc) * 0.65;
            c.rgb *= vig;

            c.rgb *= 0.72;

            return float4(c.rgb, 1.0);
        }
        """

        do {
            return try device.makeLibrary(source: src, options: nil)
        } catch {
            print("[Resona] Shader compile error: \(error)")
            return nil
        }
    }
}

// MARK: - AnimatedArtworkView (fluid waves + static album art)

final class AnimatedArtworkView: NSView {

    // ── THERMAL FIX 2: Single CIContext shared across ALL instances and ALL song changes.
    // CIContext allocation creates GPU command queues — doing this per-song-change
    // was causing a measurable CPU/GPU spike. One context lives for the app lifetime.
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    // Keep a weak reference so the controller can update colors between songs
    // without rebuilding the view hierarchy.
    private(set) weak var fluidView: FluidWaveView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called both on first show AND on subsequent song changes.
    /// On first call: builds the full layer stack including the Metal fluid view.
    /// On subsequent calls: updates only the artwork CALayer and kicks off a
    /// background color extraction — the FluidWaveView is NEVER torn down.
    func configure(with image: NSImage, scale: CGFloat) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        if fluidView == nil {
            // First configuration — build the full stack
            buildFullStack(cg: cg, scale: scale)
        } else {
            // Subsequent song change — only swap the artwork, keep Metal alive
            updateArtworkOnly(cg: cg, scale: scale)
        }

        // ── THERMAL FIX 3: Color extraction runs on a BACKGROUND THREAD.
        // The 10× CIAreaAverage calls previously ran on the main thread during
        // song transitions, causing a synchronous CPU+GPU burst that spiked temps.
        // Now the FluidWaveView keeps animating with the current palette while
        // the new palette is computed quietly in the background.
        let capturedFluid = fluidView
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (palette, dominant) = self.extractPaletteAndDominant(from: cg, count: 5)
            DispatchQueue.main.async {
                capturedFluid?.updateColors(from: palette)
                // Update the glow color without rebuilding the layer
                self.updateGlowColor(dominant, in: self.bounds)
            }
        }
    }

    // MARK: - Private: Full Initial Build

    private var glowLayer: CAGradientLayer?

    private func buildFullStack(cg: CGImage, scale: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let artSize = min(bounds.width, bounds.height) * 0.38
        let artCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let artFrame = CGRect(x: artCenter.x - artSize/2, y: artCenter.y - artSize/2,
                              width: artSize, height: artSize)
        let corner = artSize * 0.06

        // ── 1. Fluid wave background (Metal GPU shader) ────────────────
        if let fluid = FluidWaveView.create(frame: bounds) {
            // Start with neutral palette — background extraction will update it shortly
            fluid.updateColors(from: [.systemPurple, .systemBlue, .systemTeal, .systemIndigo, .systemPink])
            fluid.autoresizingMask = [.width, .height]
            addSubview(fluid)
            fluidView = fluid
        } else {
            // Fallback: static blurred background when Metal unavailable
            let bg = CALayer()
            bg.frame = bounds
            bg.contents = blurredImage(cg)
            bg.contentsGravity = .resizeAspectFill
            bg.contentsScale = scale
            layer?.addSublayer(bg)
        }

        // ── 2. Transparent overlay (sits above FluidWaveView) ─────────
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        // ── 3. Ambient glow behind artwork (placeholder color — updated async) ─
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = artFrame.insetBy(dx: -artSize * 0.45, dy: -artSize * 0.45)
        glow.colors = [NSColor.gray.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 1.0)
        glow.opacity = 0.55
        overlay.layer?.addSublayer(glow)
        glowLayer = glow

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.4; pulse.toValue = 0.75
        pulse.duration = 4; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "glowPulse")

        // ── 4. Shadow beneath artwork ──────────────────────────────────
        let shadow = CALayer()
        shadow.frame = artFrame
        shadow.cornerRadius = corner
        shadow.backgroundColor = NSColor.black.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.shadowRadius = 30; shadow.shadowOpacity = 0.85
        overlay.layer?.addSublayer(shadow)

        // ── 5. Album art — static, centered ────────────────────────────
        let art = CALayer()
        art.frame = artFrame
        art.contents = cg
        art.contentsGravity = .resizeAspectFill
        art.cornerRadius = corner; art.masksToBounds = true
        art.contentsScale = scale
        overlay.layer?.addSublayer(art)
    }

    // MARK: - Private: Lightweight Song-Change Update

    /// Only swaps the artwork CGImage on the existing CALayer. The Metal fluid view
    /// continues running at 60fps completely undisturbed. No GPU pipeline rebuild.
    private func updateArtworkOnly(cg: CGImage, scale: CGFloat) {
        // Find the art layer in the overlay and update its contents
        // The overlay is always the second subview (index 1)
        guard subviews.count >= 2,
              let overlayLayer = subviews[1].layer else { return }

        // The art layer is the last sublayer of the overlay
        if let artLayer = overlayLayer.sublayers?.last {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            artLayer.contents = cg
            CATransaction.commit()
        }
    }

    /// Updates the glow layer color after async palette extraction completes.
    private func updateGlowColor(_ color: NSColor, in bounds: CGRect) {
        guard let glow = glowLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0)
        glow.colors = [color.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        CATransaction.commit()
    }

    // MARK: - Color Extraction (runs on background thread)
    //
    // ── THERMAL FIX 2 + 4 combined:
    // - Uses the static sharedCIContext (no allocation spike)
    // - Computes dominant color IN THE SAME PASS as the palette (no second CIFilter run)
    // - Called only from a background DispatchQueue.global thread
    //
    // Algorithm:
    // Step 1: Sample 10 regions via CIAreaAverage (3×3 grid + center crop)
    // Step 2: The center crop color is used as the "dominant" color (no second pass)
    // Step 3: Pick the 5 most visually distinct colors using farthest-first selection
    // Step 4: Gently boost saturation for vibrant fluid rendering
    // Step 5: diversifyIfNeeded as safety net for monochromatic covers

    private func extractPaletteAndDominant(from cg: CGImage, count: Int) -> ([NSColor], NSColor) {
        let ci = CIImage(cgImage: cg)
        let ext = ci.extent
        // Use the shared CIContext — not a local one
        let ctx = Self.sharedCIContext

        // 3×3 grid covers all spatial regions of the art
        let cols = 3, rows = 3
        let cellW = ext.width  / CGFloat(cols)
        let cellH = ext.height / CGFloat(rows)
        var regions: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                regions.append(CGRect(x: ext.minX + CGFloat(col) * cellW,
                                      y: ext.minY + CGFloat(row) * cellH,
                                      width: cellW, height: cellH))
            }
        }
        // Center crop (inner 50%) — captures the main subject
        let centerCrop = CGRect(x: ext.minX + ext.width * 0.25,
                                y: ext.minY + ext.height * 0.25,
                                width: ext.width * 0.5, height: ext.height * 0.5)
        regions.append(centerCrop)

        // Sample average color from each region using the shared CIContext
        var sampled: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        for region in regions {
            guard let f = CIFilter(name: "CIAreaAverage") else { continue }
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(cgRect: region), forKey: "inputExtent")
            guard let out = f.outputImage else { continue }
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            sampled.append((CGFloat(px[0])/255, CGFloat(px[1])/255, CGFloat(px[2])/255))
        }

        let fallbackPalette: [NSColor] = [.systemPurple, .systemBlue, .systemTeal, .systemIndigo, .systemPink]
        let fallbackDominant: NSColor = .gray

        guard !sampled.isEmpty else {
            return (fallbackPalette, fallbackDominant)
        }

        // ── THERMAL FIX 4: Dominant color comes from the center crop sample (last index).
        // Previously dominantColor() ran a SEPARATE CIAreaAverage on the full image,
        // which meant 11 CIFilter passes per song change instead of 10.
        // Now we just reuse sampled[last] which IS the center crop average.
        let centerSample = sampled.last ?? sampled[0]
        let dominantColor = NSColor(red: centerSample.r, green: centerSample.g,
                                    blue: centerSample.b, alpha: 1)

        // Pick the `count` most distinct colors using greedy farthest-first
        var picked: [Int] = []
        let startIdx = sampled.count - 1  // Start with center crop (the "subject")
        picked.append(startIdx)

        while picked.count < min(count, sampled.count) {
            var bestIdx = -1
            var bestMinDist: CGFloat = -1
            for (i, c) in sampled.enumerated() {
                guard !picked.contains(i) else { continue }
                let minDist = picked.map { pi -> CGFloat in
                    let p = sampled[pi]
                    let dr = c.r - p.r, dg = c.g - p.g, db = c.b - p.b
                    return dr*dr + dg*dg + db*db
                }.min() ?? 0
                if minDist > bestMinDist { bestMinDist = minDist; bestIdx = i }
            }
            if bestIdx >= 0 { picked.append(bestIdx) }
            else { break }
        }

        // Convert to NSColor with gentle saturation boost for vibrant fluid rendering
        var colors: [NSColor] = picked.map { idx in
            let c = sampled[idx]
            let base = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h, saturation: min(s * 1.2, 1.0), brightness: b, alpha: 1)
        }

        while colors.count < count { colors.append(colors.last ?? .systemPurple) }
        let finalPalette = diversifyIfNeeded(colors)

        return (finalPalette, dominantColor)
    }

    /// When all palette colors are too similar (monochromatic covers like MBDTF),
    /// generate visible variations from the dominant hue so the fluid has visible waves.
    private func diversifyIfNeeded(_ colors: [NSColor]) -> [NSColor] {
        let hsbColors = colors.compactMap { $0.usingColorSpace(.deviceRGB) }
        guard let first = hsbColors.first else { return colors }

        var hues: [CGFloat] = [], brights: [CGFloat] = []
        for c in hsbColors {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            hues.append(h); brights.append(b)
        }

        let hueSpread = (hues.max() ?? 0) - (hues.min() ?? 0)
        let brightSpread = (brights.max() ?? 0) - (brights.min() ?? 0)
        let effectiveHueSpread = min(hueSpread, 1.0 - hueSpread)

        if effectiveHueSpread > 0.08 || brightSpread > 0.15 {
            return colors // Already diverse enough
        }

        // Monochromatic — build a rich palette from the dominant color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        first.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        return [
            NSColor(hue: h, saturation: s, brightness: b, alpha: 1),
            NSColor(hue: fmod(h + 0.04, 1.0), saturation: max(s - 0.1, 0.2), brightness: min(b + 0.15, 1.0), alpha: 1),
            NSColor(hue: fmod(h - 0.05 + 1.0, 1.0), saturation: min(s + 0.15, 1.0), brightness: max(b - 0.25, 0.15), alpha: 1),
            NSColor(hue: fmod(h + 0.08, 1.0), saturation: min(s + 0.1, 1.0), brightness: b, alpha: 1),
            NSColor(hue: h, saturation: max(s - 0.3, 0.05), brightness: min(b + 0.25, 1.0), alpha: 1),
        ]
    }

    // Fallback for non-Metal systems — static blurred background
    private func blurredImage(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ci, forKey: kCIInputImageKey)
        blur.setValue(60.0, forKey: kCIInputRadiusKey)
        guard let b = blur.outputImage,
              let color = CIFilter(name: "CIColorControls") else { return nil }
        color.setValue(b, forKey: kCIInputImageKey)
        color.setValue(1.4, forKey: kCIInputSaturationKey)
        color.setValue(-0.06, forKey: kCIInputBrightnessKey)
        guard let out = color.outputImage else { return nil }
        // Uses shared context here too
        return Self.sharedCIContext.createCGImage(out, from: ci.extent)
    }
}