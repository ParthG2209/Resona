import AppKit
import AVFoundation
import CoreImage

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

// MARK: - AnimatedArtworkView

final class AnimatedArtworkView: NSView {

    private var bgLayer: CALayer!
    private var artLayer: CALayer!
    private var shadowLayer: CALayer!
    private var glowLayer: CAGradientLayer!
    private var artCenter: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with image: NSImage, scale: CGFloat) {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let artSize = min(bounds.width, bounds.height) * 0.42
        artCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let artFrame = CGRect(x: artCenter.x - artSize/2, y: artCenter.y - artSize/2,
                              width: artSize, height: artSize)
        let corner = artSize * 0.04

        // 1 — Blurred background (oversized for Ken Burns)
        let oversized = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 0.1)
        bgLayer = CALayer()
        bgLayer.frame = oversized
        bgLayer.contents = blurredImage(cg)
        bgLayer.contentsGravity = .resizeAspectFill
        bgLayer.contentsScale = scale
        layer?.addSublayer(bgLayer)

        // 2 — Dark overlay
        let dark = CALayer()
        dark.frame = bounds
        dark.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.addSublayer(dark)

        // 3 — Radial vignette
        let vig = CAGradientLayer()
        vig.type = .radial; vig.frame = bounds
        vig.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        vig.locations = [0.3, 1.0]
        vig.startPoint = CGPoint(x: 0.5, y: 0.5)
        vig.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(vig)

        // 4 — Ambient glow (dominant color)
        let avg = dominantColor(of: cg)
        glowLayer = CAGradientLayer()
        glowLayer.type = .radial
        glowLayer.frame = artFrame.insetBy(dx: -artSize * 0.35, dy: -artSize * 0.35)
        glowLayer.colors = [avg.withAlphaComponent(0.45).cgColor, NSColor.clear.cgColor]
        glowLayer.locations = [0, 1]
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        glowLayer.opacity = 0.6
        layer?.addSublayer(glowLayer)

        // 5 — Shadow
        shadowLayer = CALayer()
        shadowLayer.frame = artFrame
        shadowLayer.cornerRadius = corner
        shadowLayer.backgroundColor = NSColor.black.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        shadowLayer.shadowRadius = 25; shadowLayer.shadowOpacity = 0.75
        layer?.addSublayer(shadowLayer)

        // 6 — Sharp artwork
        artLayer = CALayer()
        artLayer.frame = artFrame
        artLayer.contents = cg
        artLayer.contentsGravity = .resizeAspectFill
        artLayer.cornerRadius = corner; artLayer.masksToBounds = true
        artLayer.contentsScale = scale
        layer?.addSublayer(artLayer)

        animate()
    }

    // MARK: - Animations

    private func animate() {
        // Ken Burns zoom on background
        addAnim(bgLayer, key: "transform.scale", from: 1.0, to: 1.12, dur: 28)

        // Ken Burns pan
        let bgC = CGPoint(x: bgLayer.frame.midX, y: bgLayer.frame.midY)
        let p = bounds.width * 0.025
        addPathAnim(bgLayer, center: bgC, radius: p, dur: 35)

        // Artwork float
        addPathAnim(artLayer, center: artCenter, radius: 5, dur: 12)
        addPathAnim(shadowLayer, center: artCenter, radius: 5, dur: 12)
        addPathAnim(glowLayer,
                    center: CGPoint(x: glowLayer.frame.midX, y: glowLayer.frame.midY),
                    radius: 5, dur: 12)

        // Artwork breathe
        addAnim(artLayer, key: "transform.scale", from: 1.0, to: 1.018, dur: 4.5)
        addAnim(shadowLayer, key: "transform.scale", from: 1.0, to: 1.018, dur: 4.5)

        // Glow pulse
        addAnim(glowLayer, key: "opacity", from: 0.5, to: 0.85, dur: 3.5)

        // Shadow pulse
        addAnim(shadowLayer, key: "shadowRadius", from: 25, to: 40, dur: 3.5)
    }

    private func addAnim(_ layer: CALayer, key: String, from: Any, to: Any, dur: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from; a.toValue = to
        a.duration = dur; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: key)
    }

    private func addPathAnim(_ layer: CALayer, center: CGPoint, radius r: CGFloat, dur: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: "position")
        a.values = [
            NSValue(point: center),
            NSValue(point: CGPoint(x: center.x + r, y: center.y + r * 0.6)),
            NSValue(point: CGPoint(x: center.x - r * 0.7, y: center.y + r)),
            NSValue(point: CGPoint(x: center.x - r, y: center.y - r * 0.4)),
            NSValue(point: CGPoint(x: center.x + r * 0.5, y: center.y - r * 0.8)),
            NSValue(point: center),
        ]
        a.duration = dur; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "pathMove")
    }

    // MARK: - Image Processing

    private func blurredImage(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ci, forKey: kCIInputImageKey)
        blur.setValue(60.0, forKey: kCIInputRadiusKey)
        guard let b = blur.outputImage else { return nil }

        guard let color = CIFilter(name: "CIColorControls") else { return nil }
        color.setValue(b, forKey: kCIInputImageKey)
        color.setValue(1.4, forKey: kCIInputSaturationKey)
        color.setValue(-0.06, forKey: kCIInputBrightnessKey)
        guard let out = color.outputImage else { return nil }

        return CIContext().createCGImage(out, from: ci.extent)
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
}
