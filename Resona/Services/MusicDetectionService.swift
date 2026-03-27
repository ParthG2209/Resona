import Foundation
import Combine

// MARK: - MusicDetectionService

/// Central coordinator. Listens to both SpotifyService and AppleMusicService,
/// decides which source wins, and drives WallpaperManager updates.
final class MusicDetectionService: ObservableObject {

    static let shared = MusicDetectionService()

    private init() {
        setupObservers()
    }

    // MARK: - Sub-services

    let spotify     = SpotifyService.shared
    let appleMusic  = AppleMusicService.shared

    // MARK: - Published State

    @Published private(set) var activeTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var activeSource: MusicSource?
    @Published var showServiceConflictPrompt = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let wallpaperManager = WallpaperManager.shared

    // MARK: - Lifecycle

    func startMonitoring() {
        if AppSettings.shared.spotifyConnected {
            spotify.startPolling()
        }
        if AppSettings.shared.appleMusicConnected {
            appleMusic.startMonitoring()
        }
    }

    func stopMonitoring() {
        spotify.stopPolling()
        appleMusic.stopMonitoring()
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
            let spotifyPlaying     = spotify.playbackState == .playing
            let appleMusicPlaying  = appleMusic.playbackState == .playing

            if spotifyPlaying && appleMusicPlaying {
                // Both playing simultaneously — ask user
                DispatchQueue.main.async {
                    self.showServiceConflictPrompt = true
                    NotificationCenter.default.post(name: .serviceConflictDetected, object: nil)
                }
            } else {
                applyTrack(newTrack)
            }
        }
    }

    /// Called when user resolves a service conflict by picking one.
    func resolveConflict(preferring source: MusicSource) {
        showServiceConflictPrompt = false
        let track = source == .spotify ? spotify.currentTrack : appleMusic.currentTrack
        if let track = track {
            applyTrack(track)
        }
    }

    // MARK: - Applying Track

    private func applyTrack(_ track: Track) {
        guard AppSettings.shared.isEnabled else { return }

        activeTrack  = track
        activeSource = track.source
        playbackState = .playing

        Logger.info("Applying track: \(track.name) from \(track.source.displayName)", category: .general)
        wallpaperManager.update(for: track)
    }

    // MARK: - Stop Logic

    private func checkIfBothStopped() {
        let spotifyStopped     = spotify.playbackState == .stopped
        let appleMusicStopped  = appleMusic.playbackState == .stopped

        if spotifyStopped && appleMusicStopped {
            playbackState = .stopped
            activeTrack   = nil

            if AppSettings.shared.onMusicStop == .revertToUserWallpaper {
                wallpaperManager.revertToUserWallpaper()
            }
            // .keepLastArt → do nothing, wallpaper stays as-is
        }
    }
}
