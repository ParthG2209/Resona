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

    // MARK: - Deep Sleep State
    //
    // Tracks whether Music.app is currently running so we can pause the expensive
    // 2-second AppleScript polling subprocess when it isn't. The distributed
    // notification observer stays active at all times (it costs nothing when idle)
    // so we never miss a track change if the user relaunches Music.app.
    private var isMusicAppRunning = false
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Authorization (AppleScript-based — no MusicKit needed)

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

    // MARK: - Monitoring
    //
    // Three layers, each cheaper than the last when Music.app is absent:
    //
    // 1. DistributedNotificationCenter — zero cost when Music isn't running.
    //    Fires instantly when Music.app posts a playerInfo notification.
    //
    // 2. NSWorkspace launch/terminate observers — used to flip isMusicAppRunning,
    //    which gates whether the AppleScript timer is active. Costs nothing.
    //
    // 3. AppleScript poll every 2s — only runs while isMusicAppRunning == true.
    //    Previously this spawned an NSAppleScript subprocess unconditionally,
    //    even when Music.app was not open. Now it pauses automatically.

    func startMonitoring() {
        stopMonitoring()
        isAuthenticated = true
        print("[Resona] Apple Music: startMonitoring called")

        // Approach 1: Instant distributed notification (always active, zero cost)
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

        // Approach 2: NSWorkspace observers to track Music.app lifecycle.
        // When Music.app quits we stop spawning 2s AppleScript subprocesses.
        // When it relaunches we restart the timer immediately.
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
            print("[Resona] Apple Music: Music.app terminated — pausing AppleScript poll timer")
            self.isMusicAppRunning = false
            self.stopPollTimer()
            // Update playback state since Music is gone
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
            print("[Resona] Apple Music: Music.app launched — resuming AppleScript poll timer")
            self.isMusicAppRunning = true
            self.startPollTimer()
        }

        workspaceObservers = [terminateObserver, launchObserver]

        // Check if Music.app is already running right now before starting the timer.
        // This correctly handles the case where startMonitoring is called while
        // Music is already open (e.g. on app launch or reconnect).
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
            Task { @MainActor [weak self] in
                self?.pollViaAppleScript()
            }
        }
        print("[Resona] Apple Music: Poll timer started (2s interval)")
        // Fire once immediately so we don't wait for the first interval tick
        Task { @MainActor in
            pollViaAppleScript()
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Handle Notification

    private func handleMusicNotification(userInfo: [String: Any]) {
        let info = userInfo

        let state = info["Player State"] as? String ?? ""
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

        guard let name   = info["Name"] as? String,
              let artist = info["Artist"] as? String
        else { return }

        let album = info["Album"] as? String ?? "Unknown Album"
        processTrackChange(name: name, artist: artist, album: album)
    }

    // MARK: - AppleScript Poll (Reliable Fallback)
    //
    // Only called when isMusicAppRunning == true (enforced by the timer only
    // being active in that state). This means we never spawn an NSAppleScript
    // subprocess for an app that isn't running.

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

                // NOT_RUNNING here means Music.app quit between when we scheduled
                // this poll and when it ran. The workspace terminate observer will
                // have already (or will shortly) pause the timer — just return.
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

        print("[Resona] Apple Music: New track → \(name) – \(artist) [\(album)]")

        Task {
            var artworkURL = await fetchArtworkViaAppleScript(title: name, artist: artist)

            if artworkURL == nil {
                print("[Resona] Apple Music: AppleScript artwork failed, trying iTunes Search API...")
                artworkURL = await fetchArtworkViaITunesSearch(title: name, artist: artist, album: album)
            }

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

    // MARK: - iTunes Search API Fallback (Free, No Auth)

    private func fetchArtworkViaITunesSearch(title: String, artist: String, album: String = "") async -> URL? {
        let cleanTitle  = cleanForSearch(title)
        let cleanArtist = cleanForSearch(artist)
        let cleanAlbum  = cleanForSearch(album)
        let primaryArtist = extractPrimaryArtist(from: artist)

        if !cleanAlbum.isEmpty {
            if let url = await searchITunesAlbum(query: "\(cleanAlbum) \(primaryArtist)", expectedAlbum: album) {
                return url
            }
        }

        if !cleanAlbum.isEmpty {
            if let url = await searchITunesSong(query: "\(cleanTitle) \(cleanArtist) \(cleanAlbum)", expectedAlbum: album) {
                return url
            }
        }

        if let url = await searchITunesSong(query: "\(cleanTitle) \(primaryArtist)", expectedAlbum: album) {
            return url
        }

        if primaryArtist != cleanArtist {
            if let url = await searchITunesSong(query: "\(cleanTitle) \(cleanArtist)", expectedAlbum: album) {
                return url
            }
        }

        if !cleanAlbum.isEmpty {
            if let url = await searchITunesAlbum(query: cleanAlbum, expectedAlbum: album) {
                return url
            }
        }

        print("[Resona] Apple Music: All iTunes Search strategies failed for '\(title)' by '\(artist)' on '\(album)'")
        return nil
    }

    private func searchITunesAlbum(query: String, expectedAlbum: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty
            else { return nil }

            let normalizedAlbum = normalizeForComparison(expectedAlbum)

            for result in results {
                let resultAlbum = result["collectionName"] as? String ?? ""
                if normalizeForComparison(resultAlbum) == normalizedAlbum {
                    if let artURL = extractHighResArtwork(from: result) {
                        print("[Resona] Apple Music: iTunes album search matched '\(resultAlbum)' ✓")
                        return artURL
                    }
                }
            }

            for result in results {
                let resultAlbum = result["collectionName"] as? String ?? ""
                let n = normalizeForComparison(resultAlbum)
                if n.contains(normalizedAlbum) || normalizedAlbum.contains(n) {
                    if let artURL = extractHighResArtwork(from: result) {
                        print("[Resona] Apple Music: iTunes album search partial match '\(resultAlbum)' ✓")
                        return artURL
                    }
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    private func searchITunesSong(query: String, expectedAlbum: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  !results.isEmpty
            else { return nil }

            let normalizedAlbum = normalizeForComparison(expectedAlbum)

            for result in results {
                let resultAlbum = result["collectionName"] as? String ?? ""
                let n = normalizeForComparison(resultAlbum)
                if n == normalizedAlbum || n.contains(normalizedAlbum) || normalizedAlbum.contains(n) {
                    if let artURL = extractHighResArtwork(from: result) {
                        print("[Resona] Apple Music: iTunes song search matched album '\(resultAlbum)' ✓")
                        return artURL
                    }
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    private func extractHighResArtwork(from result: [String: Any]) -> URL? {
        guard let artworkURLString = result["artworkUrl100"] as? String else { return nil }
        let highRes = artworkURLString.replacingOccurrences(of: "100x100", with: "1000x1000")
        return URL(string: highRes)
    }

    private func cleanForSearch(_ text: String) -> String {
        var cleaned = text
        let featPatterns = ["(feat.", "(ft.", "(featuring", "[feat.", "[ft."]
        for pattern in featPatterns {
            if let range = cleaned.range(of: pattern, options: .caseInsensitive) {
                let closeChar: Character = pattern.hasPrefix("(") ? ")" : "]"
                if let closeRange = cleaned[range.upperBound...].firstIndex(of: closeChar) {
                    cleaned.removeSubrange(range.lowerBound...closeRange)
                } else {
                    cleaned = String(cleaned[..<range.lowerBound])
                }
            }
        }
        let specialChars = CharacterSet.alphanumerics.union(.whitespaces).inverted
        cleaned = cleaned.unicodeScalars.filter { !specialChars.contains($0) || $0 == " " }
            .map { String($0) }.joined()
        cleaned = cleaned.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func extractPrimaryArtist(from artist: String) -> String {
        let separators = [",", "&", " x ", " X ", " feat.", " ft.", " featuring"]
        var parts = [artist]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        let cleaned = parts.map { cleanForSearch($0) }.filter { !$0.isEmpty }
        return cleaned.max(by: { $0.count < $1.count }) ?? cleanForSearch(artist)
    }

    private func normalizeForComparison(_ text: String) -> String {
        var s = text.lowercased()
        while let open = s.range(of: "(") {
            if let close = s[open.upperBound...].firstIndex(of: ")") {
                s.removeSubrange(open.lowerBound...close)
            } else { break }
        }
        while let open = s.range(of: "[") {
            if let close = s[open.upperBound...].firstIndex(of: "]") {
                s.removeSubrange(open.lowerBound...close)
            } else { break }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AppleScript Artwork Fetch

    private func fetchArtworkViaAppleScript(title: String, artist: String) async -> URL? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tempPath = NSTemporaryDirectory() + "resona_artwork_\(UUID().uuidString).jpg"

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
            print("[Resona] Apple Music: \(track.name) – \(track.artist)")
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }
}