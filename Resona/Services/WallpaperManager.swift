import Foundation
import AppKit
import CoreImage

// MARK: - WallpaperManager

final class WallpaperManager {

    static let shared = WallpaperManager()
    private init() {}

    private let cache        = ArtworkCache.shared
    private let session      = URLSession.shared
    private var pendingTask:   URLSessionDataTask?
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let animatedCtrl  = AnimatedWallpaperController.shared

    // MARK: - Public API

    func update(for track: Track) {
        pendingTask?.cancel()

        guard let artworkURL = track.artworkURL else {
            Logger.info("No artwork for \(track.name)", category: .wallpaper)
            revertToUserWallpaper()
            return
        }

        if AppSettings.shared.showAnimatedWallpapers {
            fetchForAnimated(url: artworkURL, track: track)
        } else {
            animatedCtrl.dismiss()
            fetchForStatic(url: artworkURL, track: track)
        }
    }

    func revertToUserWallpaper() {
        animatedCtrl.dismiss()
        guard let url = AppSettings.shared.defaultWallpaperURL else {
            Logger.info("No default wallpaper set", category: .wallpaper)
            return
        }
        applyStatic(fileURL: url)
    }

    // MARK: - Animated Mode

    private func fetchForAnimated(url: URL, track: Track) {
        pendingTask = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            if (error as? URLError)?.code == .cancelled { return }
            guard let data, error == nil, let image = NSImage(data: data) else {
                Logger.error("Artwork download failed", category: .wallpaper)
                return
            }
            DispatchQueue.main.async {
                self.animatedCtrl.show(
                    artworkImage: image,
                    trackID: track.id,
                    canvasURL: track.canvasURL
                )
            }
        }
        pendingTask?.resume()
    }

    // MARK: - Static Mode (composed wallpaper)

    private func fetchForStatic(url: URL, track: Track) {
        let cacheKey = CacheKey(trackID: track.id, source: track.source, animated: false)

        if let cachedURL = cache.retrieve(for: cacheKey) {
            Logger.info("Cache hit for \(track.name)", category: .wallpaper)
            applyStatic(fileURL: cachedURL)
            return
        }

        pendingTask = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            if (error as? URLError)?.code == .cancelled { return }
            guard let data, error == nil else {
                Logger.error("Artwork download failed", category: .wallpaper)
                return
            }

            let finalData = self.composeDesktopWallpaper(from: data) ?? data

            guard let localURL = self.cache.store(data: finalData, for: cacheKey) else {
                Logger.error("Cache write failed", category: .wallpaper)
                return
            }
            self.applyStatic(fileURL: localURL)
        }
        pendingTask?.resume()
    }

    // MARK: - Apply Static

    private func applyStatic(fileURL: URL) {
        DispatchQueue.main.async { self.setWallpaper(url: fileURL) }
    }

    private func setWallpaper(url: URL) {
        let ws = NSWorkspace.shared
        let screens = AppSettings.shared.isEnabled ? NSScreen.screens : [NSScreen.main].compactMap { $0 }
        for screen in screens {
            do {
                var opts = ws.desktopImageOptions(for: screen) ?? [:]
                opts[.fillColor] = NSColor.black
                opts[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
                try ws.setDesktopImageURL(url, for: screen, options: opts)
                Logger.info("Wallpaper set: \(url.lastPathComponent)", category: .wallpaper)
            } catch {
                Logger.error("Failed to set wallpaper: \(error)", category: .wallpaper)
            }
        }
    }

    // MARK: - Composition Engine (for static mode)

    private func composeDesktopWallpaper(from artData: Data) -> Data? {
        var pixelW = 2560, pixelH = 1600
        var sf: CGFloat = 2.0
        DispatchQueue.main.sync {
            if let s = NSScreen.main {
                sf = s.backingScaleFactor
                pixelW = Int(s.frame.width * sf)
                pixelH = Int(s.frame.height * sf)
            }
        }

        guard let src = NSImage(data: artData),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let ci = CIImage(cgImage: cg)

        // Blur
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ci, forKey: kCIInputImageKey)
        blur.setValue(80.0, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage else { return nil }

        // Color adjustment
        guard let cc = CIFilter(name: "CIColorControls") else { return nil }
        cc.setValue(blurred, forKey: kCIInputImageKey)
        cc.setValue(1.4, forKey: kCIInputSaturationKey)
        cc.setValue(-0.08, forKey: kCIInputBrightnessKey)
        guard let adjusted = cc.outputImage else { return nil }

        // Scale to fill + crop
        let fillScale = max(CGFloat(pixelW) / adjusted.extent.width,
                            CGFloat(pixelH) / adjusted.extent.height) * 1.15
        let scaled = adjusted.transformed(by: .init(scaleX: fillScale, y: fillScale))
        let cx = (scaled.extent.width - CGFloat(pixelW)) / 2 + scaled.extent.minX
        let cy = (scaled.extent.height - CGFloat(pixelH)) / 2 + scaled.extent.minY
        let cropped = scaled.cropped(to: CGRect(x: cx, y: cy, width: CGFloat(pixelW), height: CGFloat(pixelH)))

        guard let bgCG = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }

        // Compose with CGContext
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let full = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        ctx.draw(bgCG, in: full)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
        ctx.fill(full)

        // Vignette
        let center = CGPoint(x: CGFloat(pixelW)/2, y: CGFloat(pixelH)/2)
        if let g = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        ] as CFArray, locations: [0.35, 1.0]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                   endCenter: center,
                                   endRadius: hypot(CGFloat(pixelW), CGFloat(pixelH))/2,
                                   options: .drawsAfterEndLocation)
        }

        // Centered artwork
        let artSz = min(CGFloat(pixelW), CGFloat(pixelH)) * 0.42
        let artRect = CGRect(x: (CGFloat(pixelW)-artSz)/2, y: (CGFloat(pixelH)-artSz)/2,
                             width: artSz, height: artSz)
        let cr = artSz * 0.04
        let path = CGPath(roundedRect: artRect, cornerWidth: cr, cornerHeight: cr, transform: nil)

        // Shadow
        ctx.saveGState()
        ctx.setShadow(offset: .init(width: 0, height: -8*sf), blur: 40*sf,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()

        // Artwork clipped
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: artRect)
        ctx.restoreGState()

        guard let final = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: final).representation(using: .jpeg, properties: [.compressionFactor: 0.90])
    }
}

// MARK: - CacheKey

struct CacheKey {
    let trackID: String
    let source: MusicSource
    let animated: Bool

    var filename: String {
        let hash = "\(source.rawValue)_\(trackID)".data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(40)
        return "\(hash).\(animated ? "mp4" : "jpg")"
    }
}
