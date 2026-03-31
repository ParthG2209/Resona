import Foundation
import Combine
import AppKit

// MARK: - Notification name for UI to show "Link Spotify" prompt

extension Notification.Name {
    /// Posted when an Apple Music track change fires but SpotifySearchService has
    /// no linked user token. The UI observes this to show the "Link Spotify" button.
    static let appleMusicNeedsSpotifyLink = Notification.Name("appleMusicNeedsSpotifyLink")
}

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

    // MARK: - Deep Sleep State (Fix 2)

    private var isMusicAppRunning = false
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Authorization

    func connect() async {
        Logger.info("🎵 Apple Music: connect() called", category: .appleMusic)
        isAuthenticated = true
        AppSettings.shared.appleMusicConnected = true
        startMonitoring()
        MusicDetectionService.shared.appleMusicConnectionChanged()

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

    // MARK: - Monitoring (detection layer — completely unchanged)

    func startMonitoring() {
        stopMonitoring()
        isAuthenticated = true
        print("[Resona] Apple Music: startMonitoring called")

        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("[Resona] Apple Music: Received distributed notification!")
            var info: [String: Any] = [:]
            notification.userInfo?.forEach { key, value in
                if let strKey = key as? String { info[strKey] = value }
            }
            Task { @MainActor [weak self] in
                self?.handleMusicNotification(userInfo: info)
            }
        }

        let ws = NSWorkspace.shared.notificationCenter

        let terminateObserver = ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music"
            else { return }
            print("[Resona] Apple Music: Music.app terminated — pausing poll timer")
            self.isMusicAppRunning = false
            self.stopPollTimer()
            self.playbackState = .stopped
            NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
        }

        let launchObserver = ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music"
            else { return }
            print("[Resona] Apple Music: Music.app launched — resuming poll timer")
            self.isMusicAppRunning = true
            self.startPollTimer()
        }

        workspaceObservers = [terminateObserver, launchObserver]

        isMusicAppRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.Music" }

        if isMusicAppRunning {
            print("[Resona] Apple Music: Music.app already running — starting poll timer")
            startPollTimer()
        } else {
            print("[Resona] Apple Music: Music.app not running — poll timer deferred until launch")
        }
    }

    func stopMonitoring() {
        if let observer = nowPlayingObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            nowPlayingObserver = nil
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        stopPollTimer()
        isMusicAppRunning = false
    }

    // MARK: - Poll Timer Management

    private func startPollTimer() {
        stopPollTimer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollViaAppleScript() }
        }
        print("[Resona] Apple Music: Poll timer started (2s interval)")
        Task { @MainActor in pollViaAppleScript() }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Handle Notification

    private func handleMusicNotification(userInfo: [String: Any]) {
        let state = userInfo["Player State"] as? String ?? ""
        print("[Resona] Apple Music notification: state=\(state)")

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

    // MARK: - AppleScript Poll

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
                        print("[Resona] Apple Music poll: AppleScript returned nil (count: \(self.pollCount))")
                    }
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if result.starts(with: "NOT_RUNNING") {
                    if self.pollCount % 15 == 0 {
                        print("[Resona] Apple Music poll: Music.app not running (count: \(self.pollCount))")
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
                        print("[Resona] Apple Music poll error: \(result)")
                    }
                    return
                }

                let parts = result.components(separatedBy: "|||")
                guard parts.count >= 3 else { return }
                let name = parts[0], artist = parts[1], album = parts[2]

                self.playbackState = .playing
                self.processTrackChange(name: name, artist: artist, album: album)
            }
        }
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
            // Quick check before the async lookup so we can warn the user promptly
            // if they haven't linked Spotify yet, without waiting for a timeout.
            let hasToken = SpotifySearchService.shared.isLinked
                        || SpotifyService.shared.currentAccessToken != nil

            if !hasToken {
                print("[Resona] Apple Music: No Spotify token — notifying UI to prompt link")
                NotificationCenter.default.post(name: .appleMusicNeedsSpotifyLink, object: nil)
                // Emit a track with no artwork so playback state is still tracked
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
            print("[Resona] Apple Music: \(track.name) – \(track.artist)")
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }
}