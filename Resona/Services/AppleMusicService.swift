import Foundation
import Combine
import AppKit

// MARK: - Notification name for UI to show "Link Spotify" prompt

extension Notification.Name {
    /// Posted when an Apple Music track change fires but no artwork could be
    /// obtained from Music.app AND there is no linked Spotify token.
    /// The UI observes this to show the "Link Spotify" button.
    static let appleMusicNeedsSpotifyLink = Notification.Name("appleMusicNeedsSpotifyLink")

    /// Posted when an Apple Music track's artwork was resolved (normally straight
    /// from Music.app, no Spotify). The UI observes this to retract the prompt.
    static let appleMusicArtworkResolved = Notification.Name("appleMusicArtworkResolved")
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
    private var stoppedWorkItem: DispatchWorkItem?   // debounces inter-track "Stopped" flickers
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

    func startMonitoring() {
        stopMonitoring()
        isAuthenticated = true
        print("[Resona] Apple Music: startMonitoring — listening for com.apple.Music.playerInfo")

        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Fix: snapshot the userInfo dictionary immediately on this thread
            // before crossing any actor boundary. This satisfies Swift 6's
            // requirement that captured vars are not mutated concurrently.
            let snapshot: [String: Any] = notification.userInfo?.reduce(into: [:]) { result, pair in
                if let key = pair.key as? String {
                    result[key] = pair.value
                }
            } ?? [:]

            Task { @MainActor [weak self] in
                self?.handleMusicNotification(userInfo: snapshot)
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
        case "Playing":
            // Cancel any pending "Stopped" notification — this is a song transition,
            // not a real stop. Music.app fires "Stopped" → "Playing" in rapid
            // succession when tracks change; without this debounce the brief
            // "Stopped" reaches MusicDetectionService.checkIfBothStopped(), which
            // sets the aggregated state to .stopped and freezes the shader.
            stoppedWorkItem?.cancel()
            stoppedWorkItem = nil
            playbackState = .playing
            // Post .playing so MusicDetectionService can update its aggregated state
            // (it was never notified of .playing before — only .stopped was posted).
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.playing)
        case "Paused":
            stoppedWorkItem?.cancel()
            stoppedWorkItem = nil
            playbackState = .paused
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.paused)
            return
        case "Stopped":
            playbackState = .stopped
            // Debounce the stopped notification — if "Playing" arrives within 0.5s
            // (as it does during normal song transitions), the work item is cancelled
            // and checkIfBothStopped() is never triggered. Real stops (user pressing
            // stop) propagate after the brief delay.
            stoppedWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard self?.playbackState == .stopped else { return }
                NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
            }
            stoppedWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
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

    private func processTrackChange(name: String, artist: String, album: String) {
        let trackID = "\(name)-\(artist)"
        guard trackID != lastSeenTrackID else { return }
        lastSeenTrackID = trackID

        print("[Resona] Apple Music: New track → \(name) – \(artist) [\(album)]")

        Task {
            // Primary artwork source: Music.app itself, no Spotify required.
            // Read identity + artwork atomically so we can detect a stale update
            // (Music advanced past this notification) and avoid showing the wrong
            // cover art. Runs off the main actor since the Apple Event is sync.
            let snapshot = await Task.detached(priority: .userInitiated) {
                MusicArtworkProvider.currentSnapshot()
            }.value

            // If Music.app's current track no longer matches this notification,
            // it's stale — a newer notification for the real current track will
            // (or already did) drive the update. Drop this one to avoid mismatched art.
            if let snapshot, !Self.namesMatch(snapshot.name, name) {
                print("[Resona] Apple Music: stale notification ('\(name)') — Music.app now on '\(snapshot.name)', dropping to avoid mismatched art")
                return
            }

            var artworkURL: URL? = snapshot?.artwork.flatMap { data in
                let key = CacheKey(trackID: trackID, source: .appleMusic, animated: false)
                return ArtworkCache.shared.store(data: data, for: key)
            }

            var canvasURL: URL?

            // Spotify is now optional — it only adds Canvas (animated) videos, and
            // serves as an artwork fallback if Music.app returned none (rare).
            let hasToken = SpotifySearchService.shared.isLinked
                        || SpotifyService.shared.currentAccessToken != nil

            if hasToken {
                if let result = await SpotifySearchService.shared.lookup(title: name, artist: artist) {
                    canvasURL = result.canvasURL
                    if artworkURL == nil { artworkURL = result.artworkURL }
                    print("[Resona] Apple Music: Spotify enhancement — canvas=\(result.canvasURL != nil ? "yes" : "no")")
                }
            } else if artworkURL == nil {
                // No Music.app art AND no Spotify — genuinely nothing to show.
                print("[Resona] Apple Music: No artwork from Music.app and no Spotify — prompting link")
                NotificationCenter.default.post(name: .appleMusicNeedsSpotifyLink, object: nil)
            }

            if artworkURL != nil {
                print("[Resona] Apple Music: artwork from \(canvasURL != nil ? "Music.app + Spotify canvas" : "Music.app")")
                NotificationCenter.default.post(name: .appleMusicArtworkResolved, object: nil)
            }

            let track = Track(
                id:         trackID,
                name:       name,
                artist:     artist,
                album:      album,
                artworkURL: artworkURL,
                canvasURL:  canvasURL,
                durationMs: 0,
                progressMs: 0,
                source:     .appleMusic
            )

            scheduleTrackUpdate(track)
        }
    }

    /// Trim/case-insensitive comparison — the playerInfo notification and the
    /// Apple Event both originate from Music.app, so exact-after-normalisation.
    private static func namesMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
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