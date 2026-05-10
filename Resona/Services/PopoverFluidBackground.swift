import AppKit
import MetalKit

// MARK: - PopoverFluidBackground
//
// A self-contained MTKView that renders the same simplex-noise fluid shader
// used by the desktop wallpaper, but tuned for the popover:
//
//   • Slower animation (0.12× the desktop speed) — more ambient, less distracting
//   • Darker output (×0.55 brightness) — acts as a readable backdrop for UI
//   • Heavier domain warp — more organic, lava-lamp quality at small size
//   • Palette is driven by PopoverPaletteSync, which mirrors the live album colours
//   • Runs at 24 fps (not 30) to stay thermally quiet — it's a popover, not a wallpaper
//
// The view is transparent so the NSVisualEffectView frosted layer above it
// adds the glass finish on top.

final class PopoverFluidBackground: MTKView, MTKViewDelegate {

    // MARK: - Shared pipeline (compiled once, reused across open/close cycles)
    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedQueue:    MTLCommandQueue?

    private var pipelineState: MTLRenderPipelineState!
    private var commandQueue:  MTLCommandQueue!
    private var startTime:     CFAbsoluteTime = 0

    // Palette — updated by PopoverPaletteSync
    private(set) var palette: [SIMD4<Float>] = PopoverFluidBackground.defaultPalette()

    // MARK: - Uniforms (must match shader layout exactly)
    private struct Uniforms {
        var time:       Float
        var speed:      Float
        var resolution: SIMD2<Float>
        var color0:     SIMD4<Float>
        var color1:     SIMD4<Float>
        var color2:     SIMD4<Float>
        var color3:     SIMD4<Float>
        var color4:     SIMD4<Float>
    }

    // MARK: - Factory

    static func make(frame: CGRect) -> PopoverFluidBackground? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let pipeline: MTLRenderPipelineState
        let queue:    MTLCommandQueue

        if let cp = cachedPipeline, let cq = cachedQueue {
            pipeline = cp; queue = cq
        } else {
            guard let q       = device.makeCommandQueue(),
                  let library = compileShader(device: device),
                  let vertFn  = library.makeFunction(name: "popoverVertex"),
                  let fragFn  = library.makeFunction(name: "popoverFragment")
            else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat            = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled      = true
            desc.colorAttachments[0].sourceRGBBlendFactor   = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            do {
                pipeline = try device.makeRenderPipelineState(descriptor: desc)
                queue    = q
                cachedPipeline = pipeline
                cachedQueue    = queue
            } catch {
                print("[Resona] PopoverFluid pipeline error: \(error)")
                return nil
            }
        }

        let view = PopoverFluidBackground(frame: frame, device: device)
        view.pipelineState = pipeline
        view.commandQueue  = queue
        return view
    }

    // MARK: - Init

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        delegate                  = self
        preferredFramesPerSecond  = 24
        isPaused                  = false
        enableSetNeedsDisplay     = false
        colorPixelFormat          = .bgra8Unorm
        clearColor                = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque           = false
        startTime                 = CFAbsoluteTimeGetCurrent()

        // Internal render at 0.75× — fluid gradients are smooth so this is invisible
        if let ml = layer as? CAMetalLayer {
            ml.contentsScale = (NSScreen.main?.backingScaleFactor ?? 2) * 0.75
            ml.isOpaque      = false
        }
    }

    required init(coder: NSCoder) { fatalError() }

    // MARK: - Palette update (called by PopoverPaletteSync on track change)

    func updatePalette(_ nsColors: [NSColor]) {
        palette = nsColors.prefix(5).map { c -> SIMD4<Float> in
            guard let rgb = c.usingColorSpace(.deviceRGB) else {
                return SIMD4<Float>(0.4, 0.1, 0.05, 1)
            }
            return SIMD4<Float>(
                Float(rgb.redComponent),
                Float(rgb.greenComponent),
                Float(rgb.blueComponent),
                1
            )
        }
        while palette.count < 5 {
            palette.append(palette.last ?? SIMD4<Float>(0.3, 0.1, 0.05, 1))
        }
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let passDesc = currentRenderPassDescriptor,
              let cmdBuf   = commandQueue.makeCommandBuffer(),
              let enc      = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        // Popover shader runs at a fixed slow speed — independent of wave intensity
        // setting (that controls the desktop wallpaper, not the popover).
        let t     = Float(CFAbsoluteTimeGetCurrent() - startTime)
        let speed = Float(0.018)   // very slow — ambient, not distracting

        var u = Uniforms(
            time:       t,
            speed:      speed,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            color0:     palette[0],
            color1:     palette[1],
            color2:     palette[2],
            color3:     palette[3],
            color4:     palette[4]
        )

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if let ml = layer as? CAMetalLayer {
            ml.contentsScale = (NSScreen.main?.backingScaleFactor ?? 2) * 0.75
        }
    }

    // MARK: - Default palette (used before any track plays)

    static func defaultPalette() -> [SIMD4<Float>] {
        [
            SIMD4<Float>(0.55, 0.08, 0.02, 1),   // deep red
            SIMD4<Float>(0.80, 0.22, 0.02, 1),   // vivid orange-red
            SIMD4<Float>(0.25, 0.04, 0.04, 1),   // dark crimson
            SIMD4<Float>(0.65, 0.15, 0.01, 1),   // amber-orange
            SIMD4<Float>(0.12, 0.02, 0.02, 1),   // near-black red
        ]
    }

    // MARK: - Embedded Metal Shader

    private static func compileShader(device: MTLDevice) -> MTLLibrary? {
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct PopoverUniforms {
            float  time;
            float  speed;
            float2 resolution;
            float4 color0, color1, color2, color3, color4;
        };

        struct V { float4 pos [[position]]; float2 uv; };

        vertex V popoverVertex(uint vid [[vertex_id]]) {
            V o;
            o.uv  = float2((vid << 1) & 2, vid & 2);
            o.pos = float4(o.uv * 2.0 - 1.0, 0.0, 1.0);
            o.uv.y = 1.0 - o.uv.y;
            return o;
        }

        // ---- Simplex noise (identical to desktop shader) ----
        float3 mod289v3(float3 x) { return x - floor(x*(1.0/289.0))*289.0; }
        float2 mod289v2(float2 x) { return x - floor(x*(1.0/289.0))*289.0; }
        float3 permute3(float3 x)  { return mod289v3(((x*34.0)+1.0)*x); }

        float snoise(float2 v) {
            const float4 C = float4(0.211324865405187, 0.366025403784439,
                                   -0.577350269189626, 0.024390243902439);
            float2 i  = floor(v + dot(v, C.yy));
            float2 x0 = v - i + dot(i, C.xx);
            float2 i1 = (x0.x > x0.y) ? float2(1,0) : float2(0,1);
            float4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = mod289v2(i);
            float3 p = permute3(permute3(i.y + float3(0,i1.y,1)) + i.x + float3(0,i1.x,1));
            float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
            m = m*m; m = m*m;
            float3 x_ = 2.0*fract(p*C.www) - 1.0;
            float3 h  = abs(x_) - 0.5;
            float3 ox = floor(x_+0.5);
            float3 a0 = x_ - ox;
            m *= 1.79284291400159 - 0.85373472095314*(a0*a0+h*h);
            float3 g;
            g.x  = a0.x *x0.x  + h.x *x0.y;
            g.yz = a0.yz*x12.xz + h.yz*x12.yw;
            return 130.0*dot(m,g);
        }

        // ---- Fragment: fluid waves with heavy warp for lava-lamp feel ----
        fragment float4 popoverFragment(V in [[stage_in]],
                                        constant PopoverUniforms &u [[buffer(0)]]) {
            float2 uv = in.uv;
            float  t  = u.time * u.speed;

            float aspect = u.resolution.x / u.resolution.y;
            float2 st = float2(uv.x * aspect, uv.y);

            // Triple domain warp — deeper than desktop, gives a denser lava-lamp feel
            float2 w1 = float2(
                snoise(st*1.4 + float2(t*0.25, t*0.18)),
                snoise(st*1.4 + float2(t*0.18,-t*0.25))
            ) * 0.22;

            float2 w2 = float2(
                snoise((st+w1)*0.9 + float2(-t*0.12, t*0.09)),
                snoise((st+w1)*0.9 + float2( t*0.09, t*0.12))
            ) * 0.16;

            float2 w3 = float2(
                snoise((st+w1+w2)*0.6 + float2(t*0.07,-t*0.05)),
                snoise((st+w1+w2)*0.6 + float2(-t*0.05, t*0.07))
            ) * 0.10;

            float2 warped = st + w1 + w2 + w3;

            float n1 = snoise(warped*1.6  + float2(t*0.35, t*0.20));
            float n2 = snoise(warped*2.4  + float2(-t*0.25, t*0.35));
            float n3 = snoise(warped*1.1  + float2(t*0.18,-t*0.30));
            float n4 = snoise(warped*3.0  + float2(-t*0.18,-t*0.13));

            float4 c = u.color0;
            c = mix(c, u.color1, smoothstep(-0.3, 0.5, n1));
            c = mix(c, u.color2, smoothstep(-0.2, 0.6, n2) * 0.75);
            c = mix(c, u.color3, smoothstep(-0.4, 0.4, n3) * 0.60);
            c = mix(c, u.color4, smoothstep(-0.3, 0.4, n4) * 0.45);

            float n5 = snoise((warped+w3*3.0)*2.0 + float2(t*0.28, t*0.10));
            c = mix(c, u.color1*0.5 + u.color2*0.5, smoothstep(-0.1, 0.6, n5)*0.35);

            // Darken significantly — the glass overlay above brightens it back up
            // and we need contrast for the UI text sitting on top.
            c.rgb *= 0.48;

            // Soft vignette
            float2 vc = uv - 0.5;
            c.rgb *= 1.0 - dot(vc, vc) * 0.55;

            // Dither to kill banding at low brightness
            float dither = fract(sin(dot(in.pos.xy, float2(12.9898,78.233)))*43758.5453);
            c.rgb += (dither/255.0) - (0.5/255.0);

            return float4(c.rgb, 1.0);
        }
        """

        do {
            return try device.makeLibrary(source: src, options: nil)
        } catch {
            print("[Resona] PopoverFluid shader compile error: \(error)")
            return nil
        }
    }
}

// MARK: - PopoverPaletteSync
//
// Singleton that listens for track changes and pushes the new colour palette
// to every active PopoverFluidBackground instance.
// Decoupled from AnimatedWallpaperController so neither depends on the other.

final class PopoverPaletteSync {

    static let shared = PopoverPaletteSync()
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paletteDidChange(_:)),
            name: .popoverPaletteDidChange,
            object: nil
        )
    }

    // Weak references — the popover view is short-lived
    private var listeners: [() -> PopoverFluidBackground?] = []
    private(set) var currentColors: [NSColor] = []

    func register(_ view: PopoverFluidBackground) {
        weak let weakView = view
        listeners.append { weakView }
        // Immediately apply current palette if we have one
        if !currentColors.isEmpty {
            view.updatePalette(currentColors)
        }
    }

    /// Called by AnimatedWallpaperController (or WallpaperManager) after
    /// palette extraction completes. Pass the same NSColor array used for
    /// FluidWaveView.updateColors(from:).
    func push(colors: [NSColor]) {
        currentColors = colors
        NotificationCenter.default.post(
            name: .popoverPaletteDidChange,
            object: colors
        )
    }

    @objc private func paletteDidChange(_ note: Notification) {
        guard let colors = note.object as? [NSColor] else { return }
        // Purge dead references while we're here
        listeners = listeners.filter { $0() != nil }
        listeners.forEach { $0()?.updatePalette(colors) }
    }
}

extension Notification.Name {
    static let popoverPaletteDidChange = Notification.Name("popoverPaletteDidChange")
}