import Foundation
import AppKit

// MARK: - WallpaperManager

/// Downloads artwork, caches it, and applies it as the macOS desktop wallpaper.
final class WallpaperManager {

    static let shared = WallpaperManager()
    private init() {}

    // MARK: - Private Properties

    private let cache     = ArtworkCache.shared
    private let session   = URLSession.shared
    private var pendingTask: URLSessionDataTask?

    // MARK: - Public API

    /// Main entry point. Called whenever the active track changes.
    func update(for track: Track) {
        // Cancel any in-flight download for a previous rapid skip
        pendingTask?.cancel()

        // Prefer animated (Canvas) if enabled and available
        let useAnimated = AppSettings.shared.showAnimatedWallpapers && track.isAnimatedArtworkAvailable

        if useAnimated, let canvasURL = track.canvasURL {
            fetchAndApply(url: canvasURL, track: track, animated: true)
        } else if let artworkURL = track.artworkURL {
            fetchAndApply(url: artworkURL, track: track, animated: false)
        } else {
            Logger.info("No artwork available for \(track.name) — reverting to user wallpaper", category: .wallpaper)
            revertToUserWallpaper()
        }
    }

    func revertToUserWallpaper() {
        guard let url = AppSettings.shared.defaultWallpaperURL else {
            Logger.info("No default wallpaper set — leaving current wallpaper", category: .wallpaper)
            return
        }
        apply(fileURL: url)
    }

    // MARK: - Fetch & Apply

    private func fetchAndApply(url: URL, track: Track, animated: Bool) {
        // Check cache first
        let cacheKey = CacheKey(trackID: track.id, source: track.source, animated: animated)

        if let cachedURL = cache.retrieve(for: cacheKey) {
            Logger.info("Cache hit for \(track.name)", category: .wallpaper)
            apply(fileURL: cachedURL)
            return
        }

        // Download artwork
        pendingTask = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }

            if let error = error as? URLError, error.code == .cancelled { return }

            guard let data = data, error == nil else {
                Logger.error("Artwork download failed: \(error?.localizedDescription ?? "unknown")", category: .wallpaper)
                return
            }

            guard let localURL = self.cache.store(data: data, for: cacheKey) else {
                Logger.error("Failed to write artwork to cache", category: .wallpaper)
                return
            }

            self.apply(fileURL: localURL)
        }
        pendingTask?.resume()
    }

    // MARK: - Apply to Desktop

    private func apply(fileURL: URL) {
        DispatchQueue.main.async {
            self.setWallpaper(url: fileURL)
        }
    }

    private func setWallpaper(url: URL) {
        let workspace = NSWorkspace.shared

        // Apply to all screens — single screen for MVP (main only)
        let screens = AppSettings.shared.isEnabled ? NSScreen.screens : [NSScreen.main].compactMap { $0 }

        for screen in screens {
            do {
                var options = workspace.desktopImageOptions(for: screen) ?? [:]
                options[NSWorkspace.DesktopImageOptionKey.fillColor] = NSColor.black

                // For images: use .scaleProportionallyUpOrDown for best look
                options[NSWorkspace.DesktopImageOptionKey.imageScaling] =
                    NSImageScaling.scaleProportionallyUpOrDown.rawValue

                try workspace.setDesktopImageURL(url, for: screen, options: options)
                Logger.info("Wallpaper set: \(url.lastPathComponent) on \(screen.localizedName)", category: .wallpaper)
            } catch {
                Logger.error("Failed to set wallpaper: \(error.localizedDescription)", category: .wallpaper)
            }
        }
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
        let ext = animated ? "mp4" : "jpg"
        return "\(hash).\(ext)"
    }
}
