import Foundation
import Combine
import ServiceManagement

// MARK: - AppSettings
//
// Every property uses @Published so SwiftUI re-renders instantly on change.
// Each didSet persists the value to UserDefaults via JSON encoding.
// init() loads saved values (or falls back to defaults).

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - General

    @Published var isEnabled: Bool           { didSet { persist("isEnabled", isEnabled) } }
    @Published var launchOnStartup: Bool     { didSet { persist("launchOnStartup", launchOnStartup) } }
    @Published var preferredService: ServicePreference { didSet { persist("preferredService", preferredService) } }

    // MARK: - Appearance

    @Published var showAnimatedWallpapers: Bool { didSet { persist("showAnimatedWallpapers", showAnimatedWallpapers) } }
    @Published var onMusicStop: StopBehavior           { didSet { persist("onMusicStop", onMusicStop) } }
    @Published var waveIntensity: Double               { didSet { persist("waveIntensity", waveIntensity) } }

    // MARK: - Advanced

    @Published var clearCacheOnQuit: Bool       { didSet { persist("clearCacheOnQuit", clearCacheOnQuit) } }
    @Published var maxCacheSizeMB: Int          { didSet { persist("maxCacheSizeMB", maxCacheSizeMB) } }
    @Published var pollingIntervalSeconds: Int  { didSet { persist("pollingIntervalSeconds", pollingIntervalSeconds) } }
    @Published var enableDebugLogging: Bool     { didSet { persist("enableDebugLogging", enableDebugLogging) } }

    // MARK: - Wallpaper

    @Published var defaultWallpaperURLString: String? { didSet { persist("defaultWallpaperURLString", defaultWallpaperURLString) } }

    var defaultWallpaperURL: URL? {
        get { defaultWallpaperURLString.flatMap { URL(string: $0) } }
        set { defaultWallpaperURLString = newValue?.absoluteString }
    }

    // MARK: - Auth State

    @Published var spotifyConnected: Bool           { didSet { persist("spotifyConnected", spotifyConnected) } }
    @Published var appleMusicConnected: Bool         { didSet { persist("appleMusicConnected", appleMusicConnected) } }
    @Published var spotifyLinkedForAppleMusic: Bool  { didSet { persist("spotifyLinkedForAppleMusic", spotifyLinkedForAppleMusic) } }
    @Published var browserTabConnected: Bool         { didSet { persist("browserTabConnected", browserTabConnected) } }

    // MARK: - Canvas Auth

    @Published var spotifySpDcCookie: String { didSet { persist("spotifySpDcCookie", spotifySpDcCookie) } }

    // MARK: - Init (load persisted values)

    private init() {
        isEnabled                  = Self.load("isEnabled")                  ?? true
        
        if #available(macOS 13.0, *) {
            launchOnStartup        = SMAppService.mainApp.status == .enabled
        } else {
            launchOnStartup        = Self.load("launchOnStartup")            ?? false
        }
        
        preferredService           = Self.load("preferredService")           ?? .both
        showAnimatedWallpapers     = Self.load("showAnimatedWallpapers")     ?? true
        onMusicStop                = Self.load("onMusicStop")                ?? .keepLastArt
        waveIntensity              = Self.load("waveIntensity")              ?? 0.5
        clearCacheOnQuit           = Self.load("clearCacheOnQuit")           ?? false
        maxCacheSizeMB             = Self.load("maxCacheSizeMB")             ?? 500
        pollingIntervalSeconds     = Self.load("pollingIntervalSeconds")     ?? 5
        enableDebugLogging         = Self.load("enableDebugLogging")         ?? false
        defaultWallpaperURLString  = Self.load("defaultWallpaperURLString")
        spotifyConnected           = Self.load("spotifyConnected")           ?? false
        appleMusicConnected        = Self.load("appleMusicConnected")        ?? false
        spotifyLinkedForAppleMusic = Self.load("spotifyLinkedForAppleMusic") ?? false
        browserTabConnected        = Self.load("browserTabConnected")        ?? false
        spotifySpDcCookie          = Self.load("spotifySpDcCookie")          ?? ""
    }

    // MARK: - Persistence helpers

    private func persist<T: Codable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Codable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Supporting Enums

enum ServicePreference: String, Codable, CaseIterable {
    // Raw value "both" is retained for back-compat with persisted prefs; it now
    // means "any source." A dedicated youtubeOnly mirrors the two music services.
    case both
    case spotifyOnly
    case appleMusicOnly
    case youtubeOnly

    var displayName: String {
        switch self {
        case .both:           return "All sources (ask if conflict)"
        case .spotifyOnly:    return "Spotify only"
        case .appleMusicOnly: return "Apple Music only"
        case .youtubeOnly:    return "YouTube / Browser only"
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