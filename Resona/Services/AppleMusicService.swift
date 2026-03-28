import Foundation
import Combine
import AppKit

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

    // MARK: - Authorization (AppleScript-based — no MusicKit needed)

    func connect() async {
        Logger.info("🎵 Apple Music: connect() called", category: .appleMusic)

        // Mark as connected — notification listener works even if Music isn't running yet
        isAuthenticated = true
        AppSettings.shared.appleMusicConnected = true
        startMonitoring()

        // Notify MusicDetectionService so it knows we're active
        MusicDetectionService.shared.appleMusicConnectionChanged()

        // Try a lightweight test against Music.app to trigger the automation permission dialog
        // This will show "Resona wants to control Music" prompt on first run
        DispatchQueue.global(qos: .utility).async {
            let testScript = """
            tell application "Music"
                if it is running then
                    return "running"
                else
                    return "not running"
                end if
            end tell
            """
            if let result = self.runAppleScript(testScript) {
                DispatchQueue.main.async {
                    Logger.info("🎵 Apple Music: Music.app is \(result)", category: .appleMusic)
                }
            } else {
                DispatchQueue.main.async {
                    Logger.info("🎵 Apple Music: AppleScript test failed — check System Settings > Privacy > Automation", category: .appleMusic)
                }
            }
        }
    }

    func disconnect() {
        stopMonitoring()
        currentTrack = nil
        playbackState = .stopped
        isAuthenticated = false
        AppSettings.shared.appleMusicConnected = false
    }

    // MARK: - Monitoring
    // Two approaches run in parallel:
    // 1. DistributedNotificationCenter — instant but can miss events
    // 2. AppleScript polling every 2s — reliable fallback

    func startMonitoring() {
        stopMonitoring()
        Logger.info("Apple Music: startMonitoring called", category: .appleMusic)

        // Approach 1: Notification listener (instant when it works)
        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Logger.info("Apple Music: Received distributed notification!", category: .appleMusic)
            var info: [String: Any] = [:]
            notification.userInfo?.forEach { key, value in
                if let strKey = key as? String { info[strKey] = value }
            }
            Task { @MainActor [weak self] in
                self?.handleMusicNotification(userInfo: info)
            }
        }

        // Approach 2: AppleScript poll every 2s (reliable fallback)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollViaAppleScript()
            }
        }

        // Also poll immediately on start
        Task { @MainActor in
            pollViaAppleScript()
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
        Logger.info("Apple Music notification: state=\(state)", category: .appleMusic)

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
        processTrackChange(name: name, artist: artist, album: album)
    }

    // MARK: - AppleScript Poll (Reliable Fallback)

    private var pollCount = 0

    private func pollViaAppleScript() {
        pollCount += 1

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = """
            tell application "Music"
                if it is running then
                    try
                        set playerState to (player state as text)
                        if playerState is "playing" then
                            set trackName to name of current track
                            set trackArtist to artist of current track
                            set trackAlbum to album of current track
                            return trackName & "|||" & trackArtist & "|||" & trackAlbum
                        else
                            return "STATE:" & playerState
                        end if
                    on error errMsg
                        return "ERROR:" & errMsg
                    end try
                else
                    return "NOT_RUNNING"
                end if
            end tell
            """

            guard let result = self?.runAppleScript(script) else {
                if let self = self, self.pollCount % 15 == 0 {
                    DispatchQueue.main.async {
                        Logger.info("Apple Music poll: AppleScript returned nil (count: \(self.pollCount))", category: .appleMusic)
                    }
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if result.starts(with: "NOT_RUNNING") {
                    if self.pollCount % 15 == 0 {
                        Logger.info("Apple Music poll: Music.app not running (count: \(self.pollCount))", category: .appleMusic)
                    }
                    return
                }

                if result.starts(with: "STATE:") {
                    let state = String(result.dropFirst(6))
                    if state == "paused" && self.playbackState != .paused {
                        self.playbackState = .paused
                    } else if state == "stopped" && self.playbackState != .stopped {
                        self.playbackState = .stopped
                        NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
                    }
                    return
                }

                if result.starts(with: "ERROR:") {
                    if self.pollCount % 15 == 0 {
                        Logger.info("Apple Music poll error: \(result)", category: .appleMusic)
                    }
                    return
                }

                // Parse "name|||artist|||album"
                let parts = result.components(separatedBy: "|||")
                guard parts.count >= 3 else { return }
                let name = parts[0], artist = parts[1], album = parts[2]

                self.playbackState = .playing
                self.processTrackChange(name: name, artist: artist, album: album)
            }
        }
    }

    // MARK: - Process Track Change (shared by both notification + poll)

    private func processTrackChange(name: String, artist: String, album: String) {
        let trackID = "\(name)-\(artist)"
        guard trackID != lastSeenTrackID else { return }
        lastSeenTrackID = trackID

        Logger.info("Apple Music: New track → \(name) – \(artist) [\(album)]", category: .appleMusic)

        Task {
            let artworkURL = await fetchArtworkViaAppleScript(title: name, artist: artist)
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

    // MARK: - AppleScript Artwork Fetch (No MusicKit / No $99 Required)
    //
    // Queries Music.app directly for the current track's artwork data.
    // The artwork is saved to a temp file and returned as a file URL.
    // This works for both Apple Music streaming tracks and local library tracks.

    private func fetchArtworkViaAppleScript(title: String, artist: String) async -> URL? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tempPath = NSTemporaryDirectory() + "resona_artwork_\(UUID().uuidString).jpg"

                // AppleScript to get artwork from the currently playing track
                let script = """
                tell application "Music"
                    if it is running then
                        try
                            set currentTrack to current track
                            set artworkData to raw data of artwork 1 of currentTrack
                            set artFile to POSIX file "\(tempPath)"
                            set fileRef to open for access artFile with write permission
                            write artworkData to fileRef
                            close access fileRef
                            return "\(tempPath)"
                        on error
                            return ""
                        end try
                    end if
                end tell
                """

                if let result = self.runAppleScript(script), !result.isEmpty {
                    let url = URL(fileURLWithPath: result)
                    if FileManager.default.fileExists(atPath: result) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - AppleScript Helper

    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            Logger.error("AppleScript error: \(error)", category: .appleMusic)
            return nil
        }
        return result.stringValue
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
