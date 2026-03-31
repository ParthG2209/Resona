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

    // MARK: - Published State

    @Published private(set) var activeTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var activeSource: MusicSource?
    @Published var showServiceConflictPrompt = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let wallpaperManager = WallpaperManager.shared

    // Guards appleMusicConnectionChanged() from calling startMonitoring() repeatedly.
    // Apple Music monitoring is always-on once started — there is no reason to restart
    // it unless it was explicitly stopped. Without this guard, every call to
    // appleMusicConnectionChanged() (which can fire from multiple paths) restarts the
    // poll timer and the workspace observers, producing the repeated log spam seen in
    // the debug output.
    private var appleMusicMonitoringActive = false

    // MARK: - Lifecycle

    func startMonitoring() {
        print("[Resona] MusicDetection: startMonitoring — spotify=\(AppSettings.shared.spotifyConnected), appleMusic=\(AppSettings.shared.appleMusicConnected)")

        if AppSettings.shared.spotifyConnected {
            spotify.startPolling()
        }

        // Apple Music monitoring starts unconditionally — it uses local AppleScript
        // and distributed notifications, no network auth required.
        if !appleMusicMonitoringActive {
            print("[Resona] Starting Apple Music monitoring")
            appleMusic.startMonitoring()
            appleMusicMonitoringActive = true
        }
    }

    /// Called when Apple Music connection state changes mid-session.
    /// Guarded so startMonitoring() is not called redundantly.
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

    func stopMonitoring() {
        spotify.stopPolling()
        appleMusic.stopMonitoring()
        appleMusicMonitoringActive = false
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
            checkIfBothStopped()
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

        case .both:
            let spotifyPlaying    = spotify.playbackState == .playing
            let appleMusicPlaying = appleMusic.playbackState == .playing

            if spotifyPlaying && appleMusicPlaying {
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
        guard AppSettings.shared.isEnabled else { return }
        activeTrack   = track
        activeSource  = track.source
        playbackState = .playing
        Logger.info("Applying track: \(track.name) from \(track.source.displayName)", category: .general)
        wallpaperManager.update(for: track)
    }

    // MARK: - Stop Logic

    private func checkIfBothStopped() {
        let spotifyStopped    = spotify.playbackState == .stopped
        let appleMusicStopped = appleMusic.playbackState == .stopped

        if spotifyStopped && appleMusicStopped {
            playbackState = .stopped
            activeTrack   = nil
            if AppSettings.shared.onMusicStop == .revertToUserWallpaper {
                wallpaperManager.revertToUserWallpaper()
            }
        }
    }
}