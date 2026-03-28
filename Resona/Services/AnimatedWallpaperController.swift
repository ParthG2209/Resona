import AppKit
import AVFoundation
import CoreImage
import MetalKit

// MARK: - AnimatedWallpaperController
/// Creates a borderless desktop-level window and displays animated album art
/// using Core Animation (Ken Burns, floating art, ambient glow, breathing shadow).
/// Also supports video playback for Spotify Canvas when available.

final class AnimatedWallpaperController {

    static let shared = AnimatedWallpaperController()
    private init() { observeScreenChanges() }

    private var windows: [NSWindow] = []
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var currentTrackID: String?
    private(set) var isShowing = false

    // MARK: - Public

    func show(artworkImage: NSImage, trackID: String, canvasURL: URL? = nil) {
        guard trackID != currentTrackID else { return }
        dismissImmediate()
        currentTrackID = trackID
        isShowing = true

        for screen in NSScreen.screens {
            let win = makeDesktopWindow(for: screen)

            if let canvasURL {
                attachVideo(to: win, url: canvasURL, screen: screen)
            } else {
                attachAnimatedArt(to: win, image: artworkImage, screen: screen)
            }

            win.alphaValue = 0
            win.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 1.0
                win.animator().alphaValue = 1
            }
            windows.append(win)
        }
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        currentTrackID = nil
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
            // Recreate windows on screen config change
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

    private func attachAnimatedArt(to window: NSWindow, image: NSImage, screen: NSScreen) {
        let view = AnimatedArtworkView(frame: screen.frame)
        view.configure(with: image, scale: screen.backingScaleFactor)
        window.contentView = view
    }

    private func attachVideo(to window: NSWindow, url: URL, screen: NSScreen) {
        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true

        // Apple Music style: single full-bleed video filling the entire screen.
        // Canvas videos are 720×1280 (portrait 9:16). We crop to fill landscape
        // using resizeAspectFill — the top/bottom of the video get cropped,
        // which is exactly what Apple Music does when showing Canvas.
        let playerLayer = AVPlayerLayer(player: player)

        // Slightly oversize the layer to ensure full coverage + allow subtle motion
        let inset = -screen.frame.height * 0.05
        playerLayer.frame = view.bounds.insetBy(dx: inset, dy: inset)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.contentsScale = screen.backingScaleFactor

        // GPU trilinear filtering for sharper upscaling (720p → screen resolution)
        playerLayer.magnificationFilter = .trilinear
        playerLayer.minificationFilter = .trilinear

        view.layer?.addSublayer(playerLayer)

        // --- Subtle color vibrancy boost (makes 720p feel richer) ---
        if let vibranceFilter = CIFilter(name: "CIColorControls", parameters: [
            kCIInputSaturationKey: 1.25,
            kCIInputContrastKey: 1.08
        ]) {
            playerLayer.filters = [vibranceFilter]
        }

        // --- Edge vignette (cinematic finish, hides crop edges) ---
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
        view.layer?.addSublayer(vignette)

        window.contentView = view
        player.play()
        queuePlayer = player
    }
}

// MARK: - FluidWaveView (Metal GPU-accelerated fluid background)

final class FluidWaveView: MTKView, MTKViewDelegate {

    // Cached across instances so the shader is only compiled once
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedQueue: MTLCommandQueue?

    private var pipelineState: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var startTime: CFAbsoluteTime = 0
    private var palette: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0.12, 0.08, 0.2, 1), count: 5)

    struct Uniforms {
        var time: Float
        var speed: Float          // wave intensity (0 = frozen, 1 = full)
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

        // Map waveIntensity (0…1) → shader speed multiplier (0.02…0.28)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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

        // ── Fractional Brownian Motion (smooth multi-octave noise) ────
        float fbm(float2 p, int octaves) {
            float value = 0.0;
            float amp = 0.5;
            float2 shift = float2(100.0, 100.0);
            float2x2 rot = float2x2(cos(0.5), sin(0.5), -sin(0.5), cos(0.5));
            for (int i = 0; i < octaves; i++) {
                value += amp * snoise(p);
                p = rot * p * 2.0 + shift;
                amp *= 0.5;
            }
            return value;
        }

        // ── Smooth cosine palette interpolation ──────────────────────
        float4 blendColors(float t, float4 c0, float4 c1, float4 c2, float4 c3, float4 c4) {
            t = clamp(t, 0.0, 1.0);
            float seg = t * 4.0;
            int idx = int(seg);
            float f = fract(seg);
            // Smooth cosine interpolation (way smoother than linear mix)
            f = f * f * (3.0 - 2.0 * f);

            float4 colors[5] = {c0, c1, c2, c3, c4};
            int i0 = clamp(idx, 0, 4);
            int i1 = clamp(idx + 1, 0, 4);
            return mix(colors[i0], colors[i1], f);
        }

        // ── Fragment: premium fluid color waves ──────────────────────
        fragment float4 fluidFragment(V in [[stage_in]],
                                       constant Uniforms &u [[buffer(0)]]) {
            float2 uv = in.uv;
            float t = u.time * u.speed;

            float aspect = u.resolution.x / u.resolution.y;
            float2 st = float2(uv.x * aspect, uv.y);

            // ── Layer 1: Large-scale flowing blobs (background) ──────
            // Triple domain warping for ultra-smooth organic shapes
            float2 q = float2(
                fbm(st * 0.7 + float2(t * 0.15, t * 0.12), 4),
                fbm(st * 0.7 + float2(t * 0.1, -t * 0.14), 4)
            );

            float2 r = float2(
                fbm((st + q * 1.6) * 0.6 + float2(-t * 0.08, t * 0.1), 4),
                fbm((st + q * 1.6) * 0.6 + float2(t * 0.12, t * 0.06), 4)
            );

            float2 s = float2(
                fbm((st + r * 1.2) * 0.8 + float2(t * 0.06, -t * 0.05), 3),
                fbm((st + r * 1.2) * 0.8 + float2(-t * 0.07, t * 0.08), 3)
            );

            // Main flow field — combines all three warp passes
            float flow1 = fbm((st + s * 0.9) * 0.5 + float2(t * 0.05), 5);

            // ── Layer 2: Medium-scale detail (midground) ─────────────
            float2 q2 = float2(
                fbm(st * 1.2 + float2(t * 0.2, -t * 0.15) + 50.0, 3),
                fbm(st * 1.2 + float2(-t * 0.18, t * 0.22) + 50.0, 3)
            );
            float flow2 = fbm((st + q2 * 0.8) * 1.0 + float2(-t * 0.1, t * 0.08) + 100.0, 4);

            // ── Layer 3: Fine shimmering detail (foreground) ─────────
            float flow3 = fbm(st * 2.5 + float2(t * 0.3, t * 0.2) + 200.0, 3);

            // ── Color mapping ────────────────────────────────────────
            // Map flow values to [0,1] range for color blending
            float colorIdx1 = flow1 * 0.5 + 0.5;
            float colorIdx2 = flow2 * 0.5 + 0.5;

            // Primary color from large blobs
            float4 primary = blendColors(colorIdx1, u.color0, u.color1, u.color2, u.color3, u.color4);
            // Secondary color from medium detail
            float4 secondary = blendColors(colorIdx2, u.color2, u.color4, u.color0, u.color3, u.color1);

            // Blend layers: primary dominates, secondary adds variety
            float layerMix = smoothstep(-0.3, 0.3, flow3) * 0.4;
            float4 c = mix(primary, secondary, layerMix);

            // ── Ambient glow / bloom ─────────────────────────────────
            // Soft radial bloom from warp intensity (brighter where flow converges)
            float warpIntensity = length(s) * 0.3;
            float4 bloom = blendColors(fract(colorIdx1 + 0.25), u.color1, u.color3, u.color0, u.color4, u.color2);
            c = mix(c, bloom, warpIntensity * 0.2);

            // ── Post-processing ──────────────────────────────────────
            // Soft vignette (pow-based for smoother falloff)
            float2 vc = uv - 0.5;
            float vig = 1.0 - pow(dot(vc, vc) * 1.8, 0.6);
            c.rgb *= clamp(vig, 0.15, 1.0);

            // Subtle brightness boost for vibrancy
            c.rgb *= 0.82;

            // Slight gamma for richer darks
            c.rgb = pow(c.rgb, float3(0.95));

            return float4(clamp(c.rgb, 0.0, 1.0), 1.0);
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

    private weak var fluidView: FluidWaveView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with image: NSImage, scale: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let artSize = min(bounds.width, bounds.height) * 0.38
        let artCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let artFrame = CGRect(x: artCenter.x - artSize/2, y: artCenter.y - artSize/2,
                              width: artSize, height: artSize)
        let corner = artSize * 0.06

        // ─── 1. Fluid wave background (Metal GPU shader) ────────────
        let palette = extractPaletteColors(from: cg, count: 5)

        if let fluid = FluidWaveView.create(frame: bounds) {
            fluid.updateColors(from: palette)
            fluid.autoresizingMask = [.width, .height]
            addSubview(fluid)
            fluidView = fluid
        } else {
            // Fallback if Metal unavailable: static blurred background
            let bg = CALayer()
            bg.frame = bounds
            bg.contents = blurredImage(cg)
            bg.contentsGravity = .resizeAspectFill
            bg.contentsScale = scale
            layer?.addSublayer(bg)
        }

        // ─── 2. Overlay for artwork (sits above FluidWaveView) ───────
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        // ─── 3. Ambient glow behind artwork ──────────────────────────
        let avg = dominantColor(of: cg)
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = artFrame.insetBy(dx: -artSize * 0.45, dy: -artSize * 0.45)
        glow.colors = [avg.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 1.0)
        glow.opacity = 0.55
        overlay.layer?.addSublayer(glow)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.4; pulse.toValue = 0.75
        pulse.duration = 4; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "glowPulse")

        // ─── 4. Shadow beneath artwork ───────────────────────────────
        let shadow = CALayer()
        shadow.frame = artFrame
        shadow.cornerRadius = corner
        shadow.backgroundColor = NSColor.black.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOffset = CGSize(width: 0, height: -8)
        shadow.shadowRadius = 30; shadow.shadowOpacity = 0.85
        overlay.layer?.addSublayer(shadow)

        // ─── 5. Album art — STATIC, centered ────────────────────────
        let art = CALayer()
        art.frame = artFrame
        art.contents = cg
        art.contentsGravity = .resizeAspectFill
        art.cornerRadius = corner; art.masksToBounds = true
        art.contentsScale = scale
        overlay.layer?.addSublayer(art)
    }

    // MARK: - Smart Color Extraction (Center-Weighted K-Means)

    private struct HSBPixel {
        var h: CGFloat; var s: CGFloat; var b: CGFloat; var weight: CGFloat
    }

    private func extractPaletteColors(from cg: CGImage, count: Int) -> [NSColor] {
        let sz = 60
        guard let ctx = CGContext(data: nil, width: sz, height: sz,
                                   bitsPerComponent: 8, bytesPerRow: sz * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return fallbackPalette()
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sz, height: sz))
        let ptr = data.bindMemory(to: UInt8.self, capacity: sz * sz * 4)

        var pixels: [HSBPixel] = []
        pixels.reserveCapacity(sz * sz)
        let center = CGFloat(sz) / 2.0

        for y in 0..<sz {
            for x in 0..<sz {
                let i = y * sz + x
                let r = CGFloat(ptr[i*4])   / 255.0
                let g = CGFloat(ptr[i*4+1]) / 255.0
                let bl = CGFloat(ptr[i*4+2]) / 255.0

                let c = NSColor(red: r, green: g, blue: bl, alpha: 1)
                var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
                c.getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)

                // Center weight: center pixels get 3×, edges get 0.5×
                let dx = (CGFloat(x) - center) / center
                let dy = (CGFloat(y) - center) / center
                let distFromCenter = sqrt(dx*dx + dy*dy)
                let centerW = max(0.5, 3.0 - distFromCenter * 2.5)

                // Soft color weight: de-prioritize backgrounds, don't remove them
                var colorW: CGFloat = 1.0
                if bb > 0.92 && ss < 0.10 { colorW = 0.05 }
                else if bb < 0.06 { colorW = 0.1 }
                else if ss < 0.05 && bb > 0.3 && bb < 0.7 { colorW = 0.15 }

                let satBoost: CGFloat = 1.0 + ss * 0.5
                pixels.append(HSBPixel(h: hh, s: ss, b: bb, weight: centerW * colorW * satBoost))
            }
        }

        guard pixels.count >= 10 else { return fallbackPalette() }

        // K-Means++ init: pick highest-weight pixel first, then farthest-weighted
        let k = count
        var centroids: [HSBPixel] = []
        centroids.append(pixels.max(by: { $0.weight < $1.weight })!)
        for _ in 1..<k {
            var bestDist: CGFloat = -1; var bestPx = pixels[0]
            for px in pixels {
                let minD = centroids.map {
                    hsbDistance((px.h, px.s, px.b), ($0.h, $0.s, $0.b))
                }.min() ?? 0
                if minD * px.weight > bestDist { bestDist = minD * px.weight; bestPx = px }
            }
            centroids.append(bestPx)
        }

        // Weighted K-Means (10 iterations)
        var assignments = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<10 {
            for (pi, px) in pixels.enumerated() {
                var bestDist: CGFloat = .greatestFiniteMagnitude; var bestK = 0
                for (ci, cent) in centroids.enumerated() {
                    let dist = hsbDistance((px.h, px.s, px.b), (cent.h, cent.s, cent.b))
                    if dist < bestDist { bestDist = dist; bestK = ci }
                }
                assignments[pi] = bestK
            }
            for ci in 0..<k {
                var sinSum: CGFloat = 0, cosSum: CGFloat = 0
                var sumS: CGFloat = 0, sumB: CGFloat = 0, totalW: CGFloat = 0
                for (pi, px) in pixels.enumerated() where assignments[pi] == ci {
                    let w = px.weight
                    sinSum += sin(px.h * .pi * 2) * w
                    cosSum += cos(px.h * .pi * 2) * w
                    sumS += px.s * w; sumB += px.b * w; totalW += w
                }
                if totalW > 0 {
                    let mh = atan2(sinSum, cosSum) / (.pi * 2)
                    centroids[ci] = HSBPixel(h: mh < 0 ? mh + 1 : mh,
                                             s: sumS / totalW, b: sumB / totalW, weight: totalW)
                }
            }
        }

        // Rank clusters by total weight
        struct Cluster { var c: HSBPixel; var w: CGFloat }
        var clusters: [Cluster] = []
        for ci in 0..<k {
            var tw: CGFloat = 0
            for (pi, px) in pixels.enumerated() where assignments[pi] == ci { tw += px.weight }
            if tw > 0 { clusters.append(Cluster(c: centroids[ci], w: tw)) }
        }
        clusters.sort { $0.w > $1.w }

        var result: [NSColor] = clusters.prefix(count).map {
            NSColor(hue: $0.c.h, saturation: $0.c.s, brightness: $0.c.b, alpha: 1)
        }
        while result.count < count { result.append(result.last ?? .systemPurple) }
        return diversifyIfNeeded(result)
    }

    private func hsbDistance(_ a: (h: CGFloat, s: CGFloat, b: CGFloat),
                             _ b: (h: CGFloat, s: CGFloat, b: CGFloat)) -> CGFloat {
        var dh = abs(a.h - b.h)
        if dh > 0.5 { dh = 1.0 - dh }
        return dh * dh * 4.0 + (a.s - b.s) * (a.s - b.s) + (a.b - b.b) * (a.b - b.b)
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
        let hSpread = min((hues.max() ?? 0) - (hues.min() ?? 0),
                          1.0 - ((hues.max() ?? 0) - (hues.min() ?? 0)))
        let bSpread = (brights.max() ?? 0) - (brights.min() ?? 0)
        if hSpread > 0.08 || bSpread > 0.15 { return colors }

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

    private func fallbackPalette() -> [NSColor] {
        [.systemPurple, .systemBlue, .systemTeal, .systemIndigo, .systemPink]
    }

    private func dominantColor(of cg: CGImage) -> NSColor {
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage") else { return .gray }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: ci.extent), forKey: "inputExtent")
        guard let out = f.outputImage else { return .gray }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(red: CGFloat(px[0])/255, green: CGFloat(px[1])/255,
                       blue: CGFloat(px[2])/255, alpha: 1)
    }

    // Fallback for non-Metal systems
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
        return CIContext().createCGImage(out, from: ci.extent)
    }
}
