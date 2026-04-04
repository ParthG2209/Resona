import Foundation
import Combine
import AppKit

// MARK: - Notification name for UI to show "Link Spotify" prompt

extension Notification.Name {
    /// Posted when an Apple Music track change fires but SpotifySearchService has
    /// no linked user token. The UI observes this to show the "Link Spotify" button.
    static let appleMusicNeedsSpotifyLink = Notification.Name("appleMusicNeedsSpotifyLink")
}

// MARK: - AppleMusicService
//
// Lightweight Apple Music detection using ONLY the native zero-cost
// `com.apple.Music.playerInfo` DistributedNotification pushed by Music.app.
//
// NO AppleScript. NO polling. NO timers.
//
// Music.app fires this notification whenever playback state changes (play, pause,
// stop, skip). It includes track metadata in .userInfo, so we never need to ask
// Music.app for anything — it tells us.
//
// Artwork and Canvas are fetched via SpotifySearchService (Spotify Web API),
// which reuses the user's existing Spotify playback token or a linked search
// token. No Apple Developer account / MusicKit subscription needed.

@MainActor
final class AppleMusicService: ObservableObject {

    static let shared = AppleMusicService()
    private init() {}

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    private var debounceWorkItem: DispatchWorkItem?
    private var lastSeenTrackID: String?
    private var nowPlayingObserver: NSObjectProtocol?

    // MARK: - Authorization

    func connect() async {
        Logger.info("🎵 Apple Music: connect() called", category: .appleMusic)
        isAuthenticated = true
        AppSettings.shared.appleMusicConnected = true
        startMonitoring()
        MusicDetectionService.shared.appleMusicConnectionChanged()
    }

    func disconnect() {
        stopMonitoring()
        currentTrack = nil
        playbackState = .stopped
        isAuthenticated = false
        AppSettings.shared.appleMusicConnected = false
    }

    // MARK: - Monitoring
    //
    // The ONLY thing we do is listen for the distributed notification.
    // Music.app pushes this every time: play, pause, stop, next track, etc.
    // Zero CPU cost when nothing is happening — the OS delivers it to us.

    func startMonitoring() {
        stopMonitoring()
        isAuthenticated = true
        print("[Resona] Apple Music: startMonitoring — listening for com.apple.Music.playerInfo")

        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            var info: [String: Any] = [:]
            notification.userInfo?.forEach { key, value in
                if let strKey = key as? String { info[strKey] = value }
            }
            Task { @MainActor [weak self] in
                self?.handleMusicNotification(userInfo: info)
            }
        }
    }

    func stopMonitoring() {
        if let observer = nowPlayingObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            nowPlayingObserver = nil
        }
    }

    // MARK: - Handle Notification

    private func handleMusicNotification(userInfo: [String: Any]) {
        let state = userInfo["Player State"] as? String ?? ""

        switch state {
        case "Playing":  playbackState = .playing
        case "Paused":   playbackState = .paused;   return
        case "Stopped":
            playbackState = .stopped
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
            return
        default: return
        }

        guard let name   = userInfo["Name"]   as? String,
              let artist = userInfo["Artist"] as? String
        else { return }

        let album = userInfo["Album"] as? String ?? "Unknown Album"
        processTrackChange(name: name, artist: artist, album: album)
    }

    // MARK: - Process Track Change
    //
    // Artwork and Canvas come entirely from SpotifySearchService, which uses a
    // per-user Authorization Code token — no shared app-level Client Credentials.
    //
    // Token priority inside SpotifySearchService.lookup():
    //   1. SpotifyService already has a valid playback token → reused, no second login
    //   2. SpotifySearchService has its own stored token → used silently
    //   3. No token at all → lookup returns nil, we post appleMusicNeedsSpotifyLink
    //      so the UI can show the "Link Spotify" prompt
    //
    // In case 3 the Track is still emitted immediately with nil artworkURL so the
    // rest of the pipeline (playback state, menu bar metadata) is not blocked.
    // Once the user links Spotify, the next track change will succeed.

    private func processTrackChange(name: String, artist: String, album: String) {
        let trackID = "\(name)-\(artist)"
        guard trackID != lastSeenTrackID else { return }
        lastSeenTrackID = trackID

        print("[Resona] Apple Music: New track → \(name) – \(artist) [\(album)]")

        Task {
            let hasToken = SpotifySearchService.shared.isLinked
                        || SpotifyService.shared.currentAccessToken != nil

            if !hasToken {
                print("[Resona] Apple Music: No Spotify token — notifying UI to prompt link")
                NotificationCenter.default.post(name: .appleMusicNeedsSpotifyLink, object: nil)
                let track = Track(id: trackID, name: name, artist: artist, album: album,
                                  artworkURL: nil, canvasURL: nil,
                                  durationMs: 0, progressMs: 0, source: .appleMusic)
                scheduleTrackUpdate(track)
                return
            }

            let spotifyResult = await SpotifySearchService.shared.lookup(title: name, artist: artist)

            if let result = spotifyResult {
                print("[Resona] Apple Music: Spotify lookup ✅ — canvas=\(result.canvasURL != nil ? "yes" : "no")")
            } else {
                print("[Resona] Apple Music: Spotify lookup returned nil — no artwork for this track")
            }

            let track = Track(
                id:         trackID,
                name:       name,
                artist:     artist,
                album:      album,
                artworkURL: spotifyResult?.artworkURL,
                canvasURL:  spotifyResult?.canvasURL,
                durationMs: 0,
                progressMs: 0,
                source:     .appleMusic
            )

            scheduleTrackUpdate(track)
        }
    }

    // MARK: - Debounce

    private func scheduleTrackUpdate(_ track: Track) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            print("[Resona] Apple Music: \(track.name) – \(track.artist)")
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }
}