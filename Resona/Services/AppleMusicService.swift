import Foundation
import MusicKit
import Combine

@MainActor
final class AppleMusicService: ObservableObject {

    static let shared = AppleMusicService()
    private init() {}

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    private var pollTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSeenTrackID: String?
    private var nowPlayingObserver: NSObjectProtocol?

    // MARK: - Authorization

    func connect() async {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            isAuthenticated = true
            AppSettings.shared.appleMusicConnected = true
            startMonitoring()
        case .denied, .restricted:
            isAuthenticated = false
        default:
            break
        }
    }

    func disconnect() {
        stopMonitoring()
        currentTrack = nil
        playbackState = .stopped
        isAuthenticated = false
        AppSettings.shared.appleMusicConnected = false
        KeychainManager.delete(forKey: Constants.AppleMusic.Keychain.userToken)
    }

    // MARK: - Monitoring
    // Music.app posts "com.apple.Music.playerInfo" via DistributedNotificationCenter
    // whenever the track changes — this is the only reliable macOS approach.

    func startMonitoring() {
        stopMonitoring()

        // Capture just the name and userInfo — both are Sendable
        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Convert [AnyHashable: Any] → [String: Any] here, before the Task boundary.
            // [String: Any] is Sendable-safe; [AnyHashable: Any] is not.
            var info: [String: Any] = [:]
            notification.userInfo?.forEach { key, value in
                if let strKey = key as? String { info[strKey] = value }
            }
            Task { @MainActor [weak self] in
                self?.handleMusicNotification(userInfo: info)
            }
        }

        // Poll every 2s as a fallback in case a notification is missed
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollFallback()
            }
        }
    }

    func stopMonitoring() {
        if let observer = nowPlayingObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            nowPlayingObserver = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Handle Notification

    private func handleMusicNotification(userInfo: [String: Any]) {
        let info = userInfo

        let state = info["Player State"] as? String ?? ""
        switch state {
        case "Playing":  playbackState = .playing
        case "Paused":   playbackState = .paused;   return
        case "Stopped":
            playbackState = .stopped
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
            return
        default: return
        }

        guard let name   = info["Name"] as? String,
              let artist = info["Artist"] as? String
        else { return }

        let album   = info["Album"] as? String ?? "Unknown Album"
        let trackID = "\(name)-\(artist)"

        guard trackID != lastSeenTrackID else { return }
        lastSeenTrackID = trackID

        Task {
            let artworkURL = await fetchArtworkURL(title: name, artist: artist)
            let track = Track(
                id:         trackID,
                name:       name,
                artist:     artist,
                album:      album,
                artworkURL: artworkURL,
                canvasURL:  nil,
                durationMs: 0,
                progressMs: 0,
                source:     .appleMusic
            )
            scheduleTrackUpdate(track)
        }
    }

    private func pollFallback() {
        // Nothing to do if already tracking a song — just keeps the timer alive
        // in case Music.app was launched after monitoring started
        guard currentTrack == nil, playbackState == .playing else { return }
        Logger.info("Apple Music poll fallback fired", category: .appleMusic)
    }

    // MARK: - MusicKit Artwork Lookup

    private func fetchArtworkURL(title: String, artist: String) async -> URL? {
        do {
            var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
            request.limit = 1
            let response = try await request.response()
            return response.songs.first?.artwork?.url(
                width:  Constants.Wallpaper.preferredArtworkSize,
                height: Constants.Wallpaper.preferredArtworkSize
            )
        } catch {
            Logger.error("MusicKit artwork lookup failed: \(error)", category: .appleMusic)
            return nil
        }
    }

    // MARK: - Debounce

    private func scheduleTrackUpdate(_ track: Track) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            Logger.info("Apple Music: \(track.name) – \(track.artist)", category: .appleMusic)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }
}
