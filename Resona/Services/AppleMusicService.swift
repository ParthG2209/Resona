import Foundation
import MediaPlayer
import MusicKit
import Combine

// MARK: - AppleMusicService

/// Handles Apple Music authorization and now-playing detection via MediaPlayer + MusicKit.
@MainActor
final class AppleMusicService: ObservableObject {

    static let shared = AppleMusicService()
    private init() {}

    // MARK: - Published State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    // MARK: - Private Properties

    private var nowPlayingObserver: NSObjectProtocol?
    private var playbackObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?
    private var musicAuthorizationStatus: MusicAuthorization.Status = .notDetermined

    // MARK: - Authorization

    func connect() async {
        // 1. Request MusicKit authorization
        let status = await MusicAuthorization.request()
        musicAuthorizationStatus = status

        switch status {
        case .authorized:
            isAuthenticated = true
            AppSettings.shared.appleMusicConnected = true
            startMonitoring()
            Logger.info("Apple Music authorized", category: .appleMusic)

        case .denied, .restricted:
            Logger.error("Apple Music authorization denied/restricted", category: .appleMusic)
            isAuthenticated = false

        case .notDetermined:
            Logger.info("Apple Music authorization not determined", category: .appleMusic)

        @unknown default:
            Logger.error("Unknown Apple Music auth status", category: .appleMusic)
        }
    }

    func disconnect() {
        stopMonitoring()
        currentTrack = nil
        playbackState = .stopped
        isAuthenticated = false
        AppSettings.shared.appleMusicConnected = false

        KeychainManager.delete(forKey: Constants.AppleMusic.Keychain.userToken)
        Logger.info("Apple Music disconnected", category: .appleMusic)
    }

    // MARK: - Monitoring (MediaPlayer Framework)

    func startMonitoring() {
        // MPNowPlayingInfoCenter gives us real-time updates without polling
        nowPlayingObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: MPMusicPlayerController.systemMusicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.handleNowPlayingChange()
        }

        playbackObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: MPMusicPlayerController.systemMusicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackStateChange()
        }

        MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
        handleNowPlayingChange()   // read current state immediately

        Logger.info("Apple Music monitoring started", category: .appleMusic)
    }

    func stopMonitoring() {
        MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()

        if let observer = nowPlayingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        nowPlayingObserver = nil
        playbackObserver = nil
        Logger.info("Apple Music monitoring stopped", category: .appleMusic)
    }

    // MARK: - Playback State Handling

    private func handlePlaybackStateChange() {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch player.playbackState {
        case .playing:  playbackState = .playing
        case .paused:   playbackState = .paused
        case .stopped, .interrupted: playbackState = .stopped
        default: break
        }
        NotificationCenter.default.post(name: .playbackStateDidChange, object: playbackState)
    }

    private func handleNowPlayingChange() {
        let player = MPMusicPlayerController.systemMusicPlayer
        guard let item = player.nowPlayingItem else {
            playbackState = .stopped
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
            return
        }

        // Fetch high-res artwork from MusicKit API for the best quality
        Task {
            await fetchAndPublishTrack(for: item)
        }
    }

    // MARK: - Track Fetching via MusicKit

    private func fetchAndPublishTrack(for item: MPMediaItem) async {
        // Use MediaPlayer info first for fast display, then upgrade with MusicKit
        let mpArtwork = item.artwork
        let fallbackArtworkURL: URL? = nil  // MediaPlayer doesn't give us a URL directly

        // Try to look up the song in MusicKit for a proper artwork URL
        var resolvedArtworkURL: URL? = fallbackArtworkURL

        if let persistentID = item.value(forProperty: MPMediaItemPropertyPersistentID) as? UInt64 {
            resolvedArtworkURL = await fetchArtworkURL(persistentID: persistentID) ?? fallbackArtworkURL
        }

        let track = Track(
            id:          item.persistentID.description,
            name:        item.title ?? "Unknown Track",
            artist:      item.artist ?? "Unknown Artist",
            album:       item.albumTitle ?? "Unknown Album",
            artworkURL:  resolvedArtworkURL,
            canvasURL:   nil,   // Not available via official Apple Music API
            durationMs:  Int(item.playbackDuration * 1000),
            progressMs:  Int(MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime * 1000),
            source:      .appleMusic
        )

        if track != currentTrack {
            scheduleTrackUpdate(track)
        }
    }

    /// Looks up a MusicKit Song by persistent ID and returns its artwork URL.
    private func fetchArtworkURL(persistentID: UInt64) async -> URL? {
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.persistentID, equalTo: MusicItemID(persistentID.description))
            let response = try await request.response()

            guard let song = response.items.first,
                  let artwork = song.artwork
            else { return nil }

            // Request 640×640 artwork
            let size = CGSize(width: Constants.Wallpaper.preferredArtworkSize,
                              height: Constants.Wallpaper.preferredArtworkSize)
            return artwork.url(width: Int(size.width), height: Int(size.height))
        } catch {
            Logger.error("MusicKit artwork fetch failed: \(error)", category: .appleMusic)
            return nil
        }
    }

    // MARK: - Debounce

    private func scheduleTrackUpdate(_ track: Track) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            Logger.info("Apple Music track changed: \(track.name) – \(track.artist)", category: .appleMusic)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.Wallpaper.debounceInterval,
            execute: workItem
        )
    }
}
