import Foundation
import Combine

// MARK: - MusicDetectionService

final class MusicDetectionService: ObservableObject {

    static let shared = MusicDetectionService()

    private init() {
        setupObservers()
    }

    // MARK: - Sub-services

    let spotify    = SpotifyService.shared
    let appleMusic = AppleMusicService.shared
    let browser    = BrowserNowPlayingService.shared

    // MARK: - Published State

    @Published private(set) var activeTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var activeSource: MusicSource?
    @Published var showServiceConflictPrompt = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let wallpaperManager = WallpaperManager.shared

    // Apple Music and browser-tab monitoring are always-on once started —
    // each is a single push notification observer, zero CPU cost.
    private var appleMusicMonitoringActive = false
    private var browserMonitoringActive = false

    // MARK: - Lifecycle

    func startMonitoring() {
        print("[Resona] MusicDetection: startMonitoring — spotify=\(AppSettings.shared.spotifyConnected), appleMusic=\(AppSettings.shared.appleMusicConnected), browserTab=\(AppSettings.shared.browserTabConnected)")

        if AppSettings.shared.spotifyConnected {
            spotify.startPolling()
        }

        // Apple Music monitoring is a single notification listener — always start it.
        if !appleMusicMonitoringActive {
            print("[Resona] Starting Apple Music monitoring (notification-only, zero CPU)")
            appleMusic.startMonitoring()
            appleMusicMonitoringActive = true
        }

        if AppSettings.shared.browserTabConnected && !browserMonitoringActive {
            print("[Resona] Starting browser tab monitoring (MediaRemote, zero CPU)")
            browser.startMonitoring()
            browserMonitoringActive = true
        }
    }

    /// Called when Apple Music connection state changes mid-session.
    func appleMusicConnectionChanged() {
        if AppSettings.shared.appleMusicConnected {
            guard !appleMusicMonitoringActive else {
                print("[Resona] MusicDetection: Apple Music already monitoring — skipping redundant start")
                return
            }
            Logger.info("MusicDetection: Apple Music connected mid-session, starting monitoring", category: .general)
            appleMusic.startMonitoring()
            appleMusicMonitoringActive = true
        } else {
            appleMusic.stopMonitoring()
            appleMusicMonitoringActive = false
        }
    }

    /// Called when the browser-tab connection toggle changes mid-session.
    func browserTabConnectionChanged() {
        if AppSettings.shared.browserTabConnected {
            guard !browserMonitoringActive else { return }
            Logger.info("MusicDetection: browser tab connected mid-session, starting monitoring", category: .general)
            browser.startMonitoring()
            browserMonitoringActive = true
        } else {
            browser.stopMonitoring()
            browserMonitoringActive = false
            checkIfAllStopped()
        }
    }

    func stopMonitoring() {
        spotify.stopPolling()
        appleMusic.stopMonitoring()
        browser.stopMonitoring()
        appleMusicMonitoringActive = false
        browserMonitoringActive = false
    }

    // MARK: - Observers

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(trackDidChange(_:)),
            name: .trackDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStateDidChange(_:)),
            name: .playbackStateDidChange,
            object: nil
        )
    }

    @objc private func trackDidChange(_ notification: Notification) {
        guard let track = notification.object as? Track else { return }
        resolveTrackUpdate(track)
    }

    @objc private func playbackStateDidChange(_ notification: Notification) {
        guard let state = notification.object as? PlaybackState else { return }
        if state == .stopped {
            checkIfAllStopped()
        } else {
            playbackState = state
        }
    }

    // MARK: - Conflict Resolution

    private func resolveTrackUpdate(_ newTrack: Track) {
        let settings = AppSettings.shared

        switch settings.preferredService {
        case .spotifyOnly:
            guard newTrack.source == .spotify else { return }
            applyTrack(newTrack)

        case .appleMusicOnly:
            guard newTrack.source == .appleMusic else { return }
            applyTrack(newTrack)

        case .youtubeOnly:
            guard newTrack.source == .youtube else { return }
            applyTrack(newTrack)

        case .both:
            // "All sources." Spotify and Apple Music can play simultaneously and
            // thrash the wallpaper, so keep the explicit conflict prompt for that
            // pair. Browser/YouTube audio is a deliberate foreground user action,
            // so it applies directly and takes over.
            let spotifyPlaying    = spotify.playbackState == .playing
            let appleMusicPlaying = appleMusic.playbackState == .playing

            if newTrack.source != .youtube, spotifyPlaying && appleMusicPlaying {
                DispatchQueue.main.async {
                    self.showServiceConflictPrompt = true
                    NotificationCenter.default.post(name: .serviceConflictDetected, object: nil)
                }
            } else {
                applyTrack(newTrack)
            }
        }
    }

    func resolveConflict(preferring source: MusicSource) {
        showServiceConflictPrompt = false
        let track = source == .spotify ? spotify.currentTrack : appleMusic.currentTrack
        if let track { applyTrack(track) }
    }

    // MARK: - Applying Track

    private func applyTrack(_ track: Track) {
        activeTrack   = track
        activeSource  = track.source
        playbackState = .playing
        
        guard AppSettings.shared.isEnabled else { return }
        
        Logger.info("Applying track: \(track.name) from \(track.source.displayName)", category: .general)
        wallpaperManager.update(for: track)
    }

    // MARK: - Stop Logic

    private func checkIfAllStopped() {
        let spotifyStopped    = spotify.playbackState == .stopped
        let appleMusicStopped = appleMusic.playbackState == .stopped
        let browserStopped    = !browserMonitoringActive || browser.playbackState == .stopped

        if spotifyStopped && appleMusicStopped && browserStopped {
            playbackState = .stopped
            activeTrack   = nil
            if AppSettings.shared.onMusicStop == .revertToUserWallpaper {
                wallpaperManager.revertToUserWallpaper()
            }
        }
    }
}