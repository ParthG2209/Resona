import Foundation
import Combine

// MARK: - AppSettings

final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private init() {}

    // MARK: - General

    @UserDefault("isEnabled", defaultValue: true)
    var isEnabled: Bool

    @UserDefault("launchOnStartup", defaultValue: false)
    var launchOnStartup: Bool

    @UserDefault("preferredService", defaultValue: ServicePreference.both)
    var preferredService: ServicePreference

    // MARK: - Appearance

    @UserDefault("showAnimatedWallpapers", defaultValue: true)
    var showAnimatedWallpapers: Bool

    @UserDefault("transitionStyle", defaultValue: TransitionStyle.fade)
    var transitionStyle: TransitionStyle

    @UserDefault("onMusicStop", defaultValue: StopBehavior.keepLastArt)
    var onMusicStop: StopBehavior

    @UserDefault("dimOnIdle", defaultValue: false)
    var dimOnIdle: Bool

    @UserDefault("waveIntensity", defaultValue: 0.5)
    var waveIntensity: Double

    // MARK: - Advanced

    @UserDefault("clearCacheOnQuit", defaultValue: false)
    var clearCacheOnQuit: Bool

    @UserDefault("maxCacheSizeMB", defaultValue: 500)
    var maxCacheSizeMB: Int

    @UserDefault("pollingIntervalSeconds", defaultValue: 1)
    var pollingIntervalSeconds: Int

    @UserDefault("enableDebugLogging", defaultValue: false)
    var enableDebugLogging: Bool

    // MARK: - Wallpaper

    @UserDefault("defaultWallpaperURLString", defaultValue: nil)
    var defaultWallpaperURLString: String?

    var defaultWallpaperURL: URL? {
        get { defaultWallpaperURLString.flatMap { URL(string: $0) } }
        set { defaultWallpaperURLString = newValue?.absoluteString }
    }

    // MARK: - Auth State

    @UserDefault("spotifyConnected", defaultValue: false)
    var spotifyConnected: Bool

    @UserDefault("appleMusicConnected", defaultValue: false)
    var appleMusicConnected: Bool

    // Whether an Apple Music user has linked a Spotify account for artwork and
    // Canvas lookups via SpotifySearchService (separate from spotifyConnected,
    // which tracks whether the user uses Spotify for playback).
    @UserDefault("spotifyLinkedForAppleMusic", defaultValue: false)
    var spotifyLinkedForAppleMusic: Bool

    // MARK: - Canvas Auth

    @UserDefault("spotifySpDcCookie", defaultValue: "")
    var spotifySpDcCookie: String
}

// MARK: - Supporting Enums

enum ServicePreference: String, Codable, CaseIterable {
    case both
    case spotifyOnly
    case appleMusicOnly

    var displayName: String {
        switch self {
        case .both:           return "Both (ask if conflict)"
        case .spotifyOnly:    return "Spotify only"
        case .appleMusicOnly: return "Apple Music only"
        }
    }
}

enum TransitionStyle: String, Codable, CaseIterable {
    case fade
    case instant

    var displayName: String {
        switch self {
        case .fade:    return "Fade (2 seconds)"
        case .instant: return "Instant"
        }
    }
}

enum StopBehavior: String, Codable, CaseIterable {
    case keepLastArt
    case revertToUserWallpaper

    var displayName: String {
        switch self {
        case .keepLastArt:           return "Keep last album art"
        case .revertToUserWallpaper: return "Revert to my wallpaper"
        }
    }
}

// MARK: - @UserDefault Property Wrapper

@propertyWrapper
struct UserDefault<T: Codable> {
    let key: String
    let defaultValue: T

    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { return defaultValue }
            return value
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}