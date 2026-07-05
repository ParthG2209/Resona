import Foundation
import Combine

// MARK: - BrowserNowPlayingService
//
// Detects audio/video playing in a browser tab (YouTube, etc.) via the
// system-wide Now Playing feed.
//
// WHY A SUBPROCESS INSTEAD OF CALLING MediaRemote DIRECTLY:
// On macOS 15.4+ Apple gated MRMediaRemoteGetNowPlayingInfo behind a private
// entitlement — an ordinary app bundle gets `nil` back (verified: in-app the
// call returns no client and no info, while the same call from an Apple-signed
// interpreter succeeds). The practical workaround, shared with the Psychodeli
// pipeline, is to spawn the vendored `mediaremote-adapter` under the SYSTEM
// `/usr/bin/perl`, which carries the `com.apple.perl` bundle id and is allowed
// to read now-playing. The adapter streams line-delimited JSON we parse here.
//
// Adapter: https://github.com/ungive/mediaremote-adapter (BSD-3), vendored in
// Resona/Vendor/mediaremote-adapter and copied into the app bundle Resources.

@MainActor
final class BrowserNowPlayingService: ObservableObject {

    static let shared = BrowserNowPlayingService()
    private init() {}

    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    private var process: Process?
    private var stdoutBuffer = Data()
    private var lastKey: String?
    private var stopped = false
    private var backoffMs = 1000

    private static let systemPerl = "/usr/bin/perl"

    /// Bundle identifiers of browsers we treat as "tab audio" sources. The
    /// adapter reports the now-playing app's bundle id, so a music app (Music,
    /// Spotify) that also owns the session is ignored here — those have their
    /// own services.
    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser"   // Arc
    ]

    // MARK: - Monitoring

    func startMonitoring() {
        stopped = false
        spawnAdapter()
    }

    func stopMonitoring() {
        stopped = true
        process?.terminate()
        process = nil
        stdoutBuffer.removeAll()
        lastKey = nil
        currentTrack = nil
        playbackState = .stopped
    }

    // MARK: - Adapter assets

    private func adapterDir() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter", isDirectory: true)
    }

    // MARK: - Spawn

    private func spawnAdapter() {
        guard let dir = adapterDir() else { return }
        let pl = dir.appendingPathComponent("mediaremote-adapter.pl")
        let fw = dir.appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.systemPerl),
              fm.fileExists(atPath: pl.path),
              fm.fileExists(atPath: fw.path) else {
            Logger.error("BrowserNowPlaying: adapter assets missing at \(dir.path)", category: .general)
            print("[Resona] BrowserNowPlaying: adapter assets missing at \(dir.path) — browser tab detection disabled")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.systemPerl)
        // --no-diff: full metadata every frame (we need artworkData each change).
        // --debounce=500: coalesce rapid state churn.
        proc.arguments = [pl.path, fw.path, "stream", "--no-diff", "--debounce=500"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // swallow adapter diagnostics

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleExit() }
        }

        do {
            try proc.run()
        } catch {
            Logger.error("BrowserNowPlaying: spawn failed — \(error)", category: .general)
            return
        }

        process = proc
        stdoutBuffer.removeAll()
        print("[Resona] BrowserNowPlaying: adapter started (mediaremote-adapter via /usr/bin/perl)")

        // Reset the restart backoff once a run survives a minute, so a flaky
        // relaunch loop doesn't permanently inflate the delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if self?.process != nil { self?.backoffMs = 1000 }
        }
    }

    private func handleExit() {
        process = nil
        guard !stopped else { return }
        let delay = backoffMs
        backoffMs = min(backoffMs * 2, 30000)
        print("[Resona] BrowserNowPlaying: adapter exited — restarting in \(delay)ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.spawnAdapter()
        }
    }

    // MARK: - Stream parsing

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
            else { continue }
            handleLine(line)
        }
        if stdoutBuffer.count > 2_000_000 { stdoutBuffer.removeAll() }   // runaway guard
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }   // non-JSON diagnostic line
        guard (obj["type"] as? String) == "data",
              let payload = obj["payload"] as? [String: Any]
        else { return }
        handlePayload(payload)
    }

    private func handlePayload(_ p: [String: Any]) {
        // Only browser sessions are "tab audio"; a music app owning the session
        // is handled by its own service.
        guard let bundleID = p["bundleIdentifier"] as? String,
              browserBundleIDs.contains(bundleID) else {
            markStoppedIfNeeded()
            return
        }

        let isPlaying = (p["playing"] as? Bool) ?? ((p["playbackRate"] as? Double ?? 0) > 0)
        guard isPlaying,
              let title = p["title"] as? String, !title.isEmpty else {
            markStoppedIfNeeded()
            return
        }

        let artist = (p["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Browser Tab"
        let album  = (p["album"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube"
        // contentItemIdentifier is stable per track; fall back to app|title|artist.
        let key = (p["contentItemIdentifier"] as? String) ?? "\(bundleID)|\(title)|\(artist)"

        guard key != lastKey else {
            playbackState = .playing
            return
        }
        lastKey = key
        playbackState = .playing
        NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.playing)

        // The now-playing feed only carries a ~120px thumbnail. For a regular
        // youtube.com/watch tab we can do far better: read the active tab's URL
        // (one Apple Event, no tab scan), pull the video id, and fetch YouTube's
        // real thumbnail (up to 1280x720). Falls back to the feed art for
        // YouTube Music (SPA — no id in the URL), Firefox (no AppleScript URL),
        // background-tab playback, or any title mismatch.
        let feedB64 = p["artworkData"] as? String
        Task { [weak self] in
            guard let self else { return }
            var artData = await self.highResYouTubeArtwork(bundleID: bundleID, nowPlayingTitle: title)
            let upgraded = artData != nil
            if artData == nil, let b64 = feedB64 { artData = Data(base64Encoded: b64) }

            var artworkURL: URL?
            if let artData, !artData.isEmpty {
                let cacheKey = CacheKey(trackID: key, source: .youtube, animated: false)
                artworkURL = ArtworkCache.shared.store(data: artData, for: cacheKey)
            }

            // The user may have skipped during the async fetch — don't apply stale art.
            guard self.lastKey == key else { return }

            let track = Track(
                id: key, name: title, artist: artist, album: album,
                artworkURL: artworkURL, canvasURL: nil,
                durationMs: 0, progressMs: 0, source: .youtube
            )
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            print("[Resona] BrowserNowPlaying: \(title) – \(artist) [\(bundleID)]\(upgraded ? " (hi-res)" : "")")
        }
    }

    // MARK: - High-res YouTube artwork (regular youtube.com/watch only)

    nonisolated private enum BrowserStyle { case chromium, safari }

    /// Scriptable browsers whose active-tab URL we can read via Apple Events.
    /// Firefox is intentionally absent — it exposes no tab URL to AppleScript.
    private static func scriptableBrowser(_ bundleID: String) -> (app: String, style: BrowserStyle)? {
        switch bundleID {
        case "com.google.Chrome":         return ("Google Chrome", .chromium)
        case "com.google.Chrome.beta":    return ("Google Chrome Beta", .chromium)
        case "com.google.Chrome.canary":  return ("Google Chrome Canary", .chromium)
        case "com.brave.Browser":         return ("Brave Browser", .chromium)
        case "com.microsoft.edgemac":     return ("Microsoft Edge", .chromium)
        case "com.vivaldi.Vivaldi":       return ("Vivaldi", .chromium)
        case "com.operasoftware.Opera":   return ("Opera", .chromium)
        case "company.thebrowser.Browser":return ("Arc", .chromium)
        case "com.apple.Safari":          return ("Safari", .safari)
        case "com.apple.SafariTechnologyPreview": return ("Safari Technology Preview", .safari)
        default: return nil
        }
    }

    private func highResYouTubeArtwork(bundleID: String, nowPlayingTitle: String) async -> Data? {
        guard let browser = Self.scriptableBrowser(bundleID) else { return nil }
        guard let tab = await Task.detached(priority: .userInitiated, operation: {
            Self.activeTab(appName: browser.app, style: browser.style)
        }).value else { return nil }

        // Regular YouTube only — music.youtube.com is an SPA with no id in the URL.
        guard let host = URLComponents(string: tab.url)?.host?.lowercased(),
              host.contains("youtube.com"), !host.contains("music.youtube.com"),
              let videoID = Self.youtubeID(from: tab.url),
              Self.titlesPlausiblyMatch(nowPlayingTitle, tab.title)
        else { return nil }

        return await Self.fetchThumbnail(videoID: videoID)
    }

    /// One Apple Event: the front window's active/current tab URL + title.
    nonisolated private static func activeTab(appName: String, style: BrowserStyle) -> (url: String, title: String)? {
        let tabRef = style == .safari ? "current tab of front window" : "active tab of front window"
        let titleProp = style == .safari ? "name" : "title"
        let src = """
        tell application "\(appName)"
            if not running then return ""
            if (count of windows) is 0 then return ""
            set t to \(tabRef)
            return (URL of t) & linefeed & (\(titleProp) of t)
        end tell
        """
        var err: NSDictionary?
        guard let result = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil else { return nil }
        let lines = (result.stringValue ?? "").components(separatedBy: "\n")
        guard let url = lines.first, !url.isEmpty else { return nil }
        return (url, lines.count > 1 ? lines[1] : "")
    }

    nonisolated private static func youtubeID(from url: String) -> String? {
        guard let range = url.range(of: "[?&]v=([A-Za-z0-9_-]{11})", options: .regularExpression) else { return nil }
        // range covers "v=<id>" possibly with leading ? or &; extract the 11-char id.
        let matched = String(url[range])
        return matched.range(of: "[A-Za-z0-9_-]{11}$", options: .regularExpression).map { String(matched[$0]) }
    }

    /// Lenient guard so a *different* front-tab video doesn't hijack the art:
    /// require a shared normalized chunk between the now-playing title and the
    /// tab title (which is "<video title> - YouTube").
    nonisolated private static func titlesPlausiblyMatch(_ nowPlaying: String, _ tabTitle: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = norm(nowPlaying)
        let b = norm(tabTitle.replacingOccurrences(of: "youtube", with: ""))
        guard a.count >= 6, b.count >= 6 else { return false }
        return b.contains(String(a.prefix(12))) || a.contains(String(b.prefix(12)))
    }

    nonisolated private static func fetchThumbnail(videoID: String) async -> Data? {
        for variant in ["maxresdefault", "sddefault", "hqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(variant).jpg") else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 2048 {
                return data   // maxres 404s when absent; hqdefault always exists
            }
        }
        return nil
    }

    private func markStoppedIfNeeded() {
        guard playbackState != .stopped else { return }
        playbackState = .stopped
        lastKey = nil
        NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
    }
}
