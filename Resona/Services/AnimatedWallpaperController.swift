import AppKit
import AVFoundation
import CoreImage
import MetalKit

// MARK: - AnimatedWallpaperController
/// Creates a borderless desktop-level window and displays animated album art
/// using a Metal GPU shader (fluid color waves) + static centered album artwork.
/// When a Spotify Canvas URL is available the looping video replaces the still
/// album-art image inside the *same* centered frame — the fluid background keeps
/// running unchanged behind it.
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
/// 6. CABasicAnimation pulse on the glow layer is explicitly stopped on dismiss().
///    CoreAnimation was previously ticking this animation on layers that had already
///    been removed from the screen, doing invisible work until the next render cycle
///    cleaned them up. removeAllAnimations() is called before the layer is discarded.

final class AnimatedWallpaperController {

    static let shared = AnimatedWallpaperController()
    private init() { observeScreenChanges() }

    // MARK: - State

    private var windows: [NSWindow] = []
    private var currentTrackID: String?
    private(set) var isShowing = false

    // Persistent art views — kept alive across song changes so Metal is never rebuilt.
    // Only the artwork image / canvas URL and color palette are swapped on track change.
    private var artViews: [AnimatedArtworkView] = []

    // MARK: - Public

    /// Show (or update) the wallpaper for the given track.
    /// - Parameters:
    ///   - artworkImage: Still album-art image used for the fluid palette and as a
    ///                   fallback when no canvas is available.
    ///   - trackID:      Stable identifier; a no-op if the same track is already shown.
    ///   - canvasURL:    Optional Spotify Canvas video URL. When supplied the looping
    ///                   video is rendered inside the centered art frame in place of
    ///                   the still image. The fluid background is unaffected.
    func show(artworkImage: NSImage, trackID: String, canvasURL: URL? = nil) {
        guard trackID != currentTrackID else { return }
        currentTrackID = trackID
        isShowing = true

        if windows.isEmpty || artViews.isEmpty {
            // First song — build the full window/view stack from scratch.
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
            for (i, artView) in artViews.enumerated() {
                let screen = NSScreen.screens[safe: i] ?? NSScreen.main ?? NSScreen.screens[0]
                artView.configure(
                    with: artworkImage,
                    canvasURL: canvasURL,
                    scale: screen.backingScaleFactor
                )
            }
        } else {
            // Subsequent song — reuse existing views; swap artwork/canvas only.
            for (i, artView) in artViews.enumerated() {
                let screen = NSScreen.screens[safe: i] ?? NSScreen.main ?? NSScreen.screens[0]
                artView.configure(
                    with: artworkImage,
                    canvasURL: canvasURL,
                    scale: screen.backingScaleFactor
                )
            }
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        currentTrackID = nil

        // Stop all CABasicAnimation loops on every art view before discarding them.
        for artView in artViews {
            artView.stopAllAnimations()
        }
        artViews.removeAll()

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
        for artView in artViews {
            artView.stopAllAnimations()
        }
        artViews.removeAll()
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
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedQueue: MTLCommandQueue?

    private var pipelineState: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var startTime: CFAbsoluteTime = 0
    private var palette: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0.12, 0.08, 0.2, 1), count: 5)

    /// Internal render scale — 0.5 means the shader runs at 50% of native Retina resolution.
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

    static func create(frame: NSRect) -> FluidWaveView? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Resona] Metal not available")
            return nil
        }

        let pipeline: MTLRenderPipelineState
        let queue: MTLCommandQueue

        if let cached = cachedPipeline, let cq = cachedQueue {
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

        if let layer = self.layer as? CAMetalLayer {
            layer.contentsScale = (NSScreen.main?.backingScaleFactor ?? 2.0) * internalScale
        }
    }

    required init(coder: NSCoder) { fatalError() }

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

        vertex V fluidVertex(uint vid [[vertex_id]]) {
            V o;
            o.uv = float2((vid << 1) & 2, vid & 2);
            o.pos = float4(o.uv * 2.0 - 1.0, 0.0, 1.0);
            o.uv.y = 1.0 - o.uv.y;
            return o;
        }

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

        fragment float4 fluidFragment(V in [[stage_in]],
                                       constant Uniforms &u [[buffer(0)]]) {
            float2 uv = in.uv;
            float t = u.time * u.speed;

            float aspect = u.resolution.x / u.resolution.y;
            float2 st = float2(uv.x * aspect, uv.y);

            float2 warp1 = float2(
                snoise(st * 1.2 + float2(t*0.3, t*0.2)),
                snoise(st * 1.2 + float2(t*0.2, -t*0.3))
            ) * 0.18;

            float2 warp2 = float2(
                snoise((st + warp1) * 0.8 + float2(-t*0.15, t*0.1)),
                snoise((st + warp1) * 0.8 + float2(t*0.1, t*0.15))
            ) * 0.12;

            float2 warped = st + warp1 + warp2;

            float n1 = snoise(warped * 1.5  + float2(t*0.4,  t*0.25));
            float n2 = snoise(warped * 2.2  + float2(-t*0.3, t*0.4));
            float n3 = snoise(warped * 1.0  + float2(t*0.2, -t*0.35));
            float n4 = snoise(warped * 2.8  + float2(-t*0.2, -t*0.15));

            float4 c = u.color0;
            c = mix(c, u.color1, smoothstep(-0.4, 0.4, n1));
            c = mix(c, u.color2, smoothstep(-0.3, 0.5, n2) * 0.7);
            c = mix(c, u.color3, smoothstep(-0.5, 0.3, n3) * 0.55);
            c = mix(c, u.color4, smoothstep(-0.35, 0.35, n4) * 0.4);

            float n5 = snoise((warped + warp2*2.0) * 1.8 + float2(t*0.35, t*0.15));
            c = mix(c, u.color1*0.6 + u.color3*0.4, smoothstep(-0.2, 0.5, n5) * 0.3);

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

// MARK: - AnimatedArtworkView (fluid waves + centered album art OR canvas video)

final class AnimatedArtworkView: NSView {

    // Single CIContext shared across ALL instances and ALL song changes.
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) weak var fluidView: FluidWaveView?

    // Stored so stopAllAnimations() can reach them from dismiss().
    private var glowLayer: CAGradientLayer?

    // Canvas video player — kept alive for the duration of a track.
    // Replaced (previous one torn down) on every song change that has a canvas.
    private var canvasPlayer: AVQueuePlayer?
    private var canvasLooper: AVPlayerLooper?
    // The CALayer that hosts the AVPlayerLayer inside the overlay.
    // Kept as a reference so we can swap it out on song changes.
    private var mediaLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public: stop CA animations before this view is discarded

    func stopAllAnimations() {
        glowLayer?.removeAllAnimations()
        stopCanvasPlayer()
        if subviews.count >= 2 {
            subviews[1].layer?.sublayers?.forEach { $0.removeAllAnimations() }
        }
    }

    /// Called both on first show AND on subsequent song changes.
    /// - Parameters:
    ///   - image:      Album art — always provided; used for the fluid palette.
    ///   - canvasURL:  When non-nil the looping video replaces the still art layer.
    ///   - scale:      Backing scale factor of the target screen.
    func configure(with image: NSImage, canvasURL: URL?, scale: CGFloat) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        if fluidView == nil {
            buildFullStack(cg: cg, canvasURL: canvasURL, scale: scale)
        } else {
            updateMediaLayer(cg: cg, canvasURL: canvasURL, scale: scale)
        }

        // Always re-derive the palette from the album art image (even for canvas
        // tracks) — the fluid background reacts to the artwork colours regardless
        // of whether a video is playing in the frame.
        let capturedFluid = fluidView
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (palette, dominant) = self.extractPaletteAndDominant(from: cg, count: 5)
            DispatchQueue.main.async {
                capturedFluid?.updateColors(from: palette)
                self.updateGlowColor(dominant, in: self.bounds)
            }
        }
    }

    // MARK: - Private: Full Initial Build

    private func buildFullStack(cg: CGImage, canvasURL: URL?, scale: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let artSize   = min(bounds.width, bounds.height) * 0.38
        let artCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let artFrame  = CGRect(
            x: artCenter.x - artSize / 2,
            y: artCenter.y - artSize / 2,
            width: artSize,
            height: artSize
        )
        let corner = artSize * 0.06

        // 1. Fluid wave background (Metal GPU shader)
        if let fluid = FluidWaveView.create(frame: bounds) {
            fluid.updateColors(from: [.systemPurple, .systemBlue, .systemTeal, .systemIndigo, .systemPink])
            fluid.autoresizingMask = [.width, .height]
            addSubview(fluid)
            fluidView = fluid
        } else {
            let bg = CALayer()
            bg.frame = bounds
            bg.contents = blurredImage(cg)
            bg.contentsGravity = .resizeAspectFill
            bg.contentsScale = scale
            layer?.addSublayer(bg)
        }

        // 2. Transparent overlay (sits above FluidWaveView)
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        // 3. Ambient glow behind the media frame
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

        // 4. Drop shadow beneath the media frame
        let shadow = CALayer()
        shadow.frame = artFrame
        shadow.cornerRadius = corner
        shadow.backgroundColor = NSColor.black.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.shadowRadius = 30; shadow.shadowOpacity = 0.85
        overlay.layer?.addSublayer(shadow)

        // 5. Media layer — either still album art or canvas video
        let newMediaLayer = makeMediaLayer(
            artFrame: artFrame,
            corner: corner,
            cg: cg,
            canvasURL: canvasURL,
            scale: scale
        )
        overlay.layer?.addSublayer(newMediaLayer)
        mediaLayer = newMediaLayer
    }

    // MARK: - Private: Lightweight Song-Change Update

    /// Swaps only the media layer (still art ↔ canvas video) without rebuilding
    /// the fluid background, glow, or shadow layers.
    private func updateMediaLayer(cg: CGImage, canvasURL: URL?, scale: CGFloat) {
        guard subviews.count >= 2,
              let overlayLayer = subviews[1].layer,
              let oldMedia = mediaLayer
        else { return }

        // Compute the same geometry as buildFullStack so sizes are consistent.
        let artSize  = min(bounds.width, bounds.height) * 0.38
        let artFrame = CGRect(
            x: bounds.midX - artSize / 2,
            y: bounds.midY - artSize / 2,
            width: artSize,
            height: artSize
        )
        let corner = artSize * 0.06

        // Stop any running canvas before replacing.
        stopCanvasPlayer()

        let newMediaLayer = makeMediaLayer(
            artFrame: artFrame,
            corner: corner,
            cg: cg,
            canvasURL: canvasURL,
            scale: scale
        )

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        overlayLayer.replaceSublayer(oldMedia, with: newMediaLayer)
        CATransaction.commit()

        mediaLayer = newMediaLayer
    }

    // MARK: - Factory: media layer (shared by build and update paths)

    /// Returns a CALayer that is either:
    ///  • A plain CALayer containing the still album-art CGImage, or
    ///  • An AVPlayerLayer hosting a silent looping canvas video.
    /// Both are clipped to a rounded rect matching `artFrame` / `corner`.
    private func makeMediaLayer(
        artFrame: CGRect,
        corner: CGFloat,
        cg: CGImage,
        canvasURL: URL?,
        scale: CGFloat
    ) -> CALayer {

        if let url = canvasURL {
            return makeCanvasLayer(url: url, artFrame: artFrame, corner: corner)
        } else {
            return makeStillArtLayer(cg: cg, artFrame: artFrame, corner: corner, scale: scale)
        }
    }

    /// Builds and starts a looping AVPlayerLayer sized to artFrame.
    private func makeCanvasLayer(url: URL, artFrame: CGRect, corner: CGFloat) -> CALayer {
        let item   = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        let looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true

        // Store strong references so ARC keeps them alive.
        canvasPlayer = player
        canvasLooper = looper

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = artFrame
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.cornerRadius = corner
        playerLayer.masksToBounds = true

        player.play()
        return playerLayer
    }

    /// Builds a plain CALayer with the still album-art image.
    private func makeStillArtLayer(cg: CGImage, artFrame: CGRect, corner: CGFloat, scale: CGFloat) -> CALayer {
        let art = CALayer()
        art.frame = artFrame
        art.contents = cg
        art.contentsGravity = .resizeAspectFill
        art.cornerRadius = corner
        art.masksToBounds = true
        art.contentsScale = scale
        return art
    }

    // MARK: - Canvas player teardown

    private func stopCanvasPlayer() {
        canvasPlayer?.pause()
        canvasPlayer = nil
        canvasLooper = nil
    }

    // MARK: - Glow colour update

    private func updateGlowColor(_ color: NSColor, in bounds: CGRect) {
        guard let glow = glowLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0)
        glow.colors = [color.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        CATransaction.commit()
    }

    // MARK: - Color Extraction (runs on background thread)

    private func extractPaletteAndDominant(from cg: CGImage, count: Int) -> ([NSColor], NSColor) {
        let ci  = CIImage(cgImage: cg)
        let ext = ci.extent
        let ctx = Self.sharedCIContext

        let cols = 3, rows = 3
        let cellW = ext.width  / CGFloat(cols)
        let cellH = ext.height / CGFloat(rows)
        var regions: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                regions.append(CGRect(
                    x: ext.minX + CGFloat(col) * cellW,
                    y: ext.minY + CGFloat(row) * cellH,
                    width: cellW, height: cellH
                ))
            }
        }
        let centerCrop = CGRect(
            x: ext.minX + ext.width  * 0.25,
            y: ext.minY + ext.height * 0.25,
            width: ext.width  * 0.5,
            height: ext.height * 0.5
        )
        regions.append(centerCrop)

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

        let fallbackPalette:  [NSColor] = [.systemPurple, .systemBlue, .systemTeal, .systemIndigo, .systemPink]
        let fallbackDominant: NSColor   = .gray

        guard !sampled.isEmpty else { return (fallbackPalette, fallbackDominant) }

        let centerSample = sampled.last ?? sampled[0]
        let dominantColor = NSColor(
            red:   centerSample.r,
            green: centerSample.g,
            blue:  centerSample.b,
            alpha: 1
        )

        var picked: [Int] = []
        picked.append(sampled.count - 1)  // start from center sample

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
            if bestIdx >= 0 { picked.append(bestIdx) } else { break }
        }

        var colors: [NSColor] = picked.map { idx in
            let c    = sampled[idx]
            let base = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h, saturation: min(s * 1.2, 1.0), brightness: b, alpha: 1)
        }
        while colors.count < count { colors.append(colors.last ?? .systemPurple) }
        return (diversifyIfNeeded(colors), dominantColor)
    }

    private func diversifyIfNeeded(_ colors: [NSColor]) -> [NSColor] {
        let hsbColors = colors.compactMap { $0.usingColorSpace(.deviceRGB) }
        guard let first = hsbColors.first else { return colors }

        var hues: [CGFloat] = [], brights: [CGFloat] = []
        for c in hsbColors {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            hues.append(h); brights.append(b)
        }

        let hueSpread    = (hues.max() ?? 0) - (hues.min() ?? 0)
        let brightSpread = (brights.max() ?? 0) - (brights.min() ?? 0)
        let effectiveHueSpread = min(hueSpread, 1.0 - hueSpread)

        if effectiveHueSpread > 0.08 || brightSpread > 0.15 { return colors }

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        first.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        return [
            NSColor(hue: h,                        saturation: s,               brightness: b,               alpha: 1),
            NSColor(hue: fmod(h + 0.04, 1.0),      saturation: max(s-0.1, 0.2), brightness: min(b+0.15, 1.0), alpha: 1),
            NSColor(hue: fmod(h - 0.05 + 1.0, 1.0),saturation: min(s+0.15,1.0), brightness: max(b-0.25, 0.15),alpha: 1),
            NSColor(hue: fmod(h + 0.08, 1.0),      saturation: min(s+0.1, 1.0), brightness: b,               alpha: 1),
            NSColor(hue: h,                        saturation: max(s-0.3, 0.05), brightness: min(b+0.25, 1.0), alpha: 1),
        ]
    }

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
        return Self.sharedCIContext.createCGImage(out, from: ci.extent)
    }
}