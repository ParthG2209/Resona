import Foundation
import AppKit
import Combine

// MARK: - SpotifyError

enum SpotifyError: LocalizedError {
    case invalidAuthURL, missingAuthCode, tokenParseFailed, noRefreshToken, noAccessToken
    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:   return "Could not construct Spotify auth URL."
        case .missingAuthCode:  return "Spotify did not return an auth code."
        case .tokenParseFailed: return "Failed to parse Spotify token response."
        case .noRefreshToken:   return "No refresh token stored."
        case .noAccessToken:    return "No access token available."
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func formEncoded() -> Data? {
        map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
    }
}

// MARK: - SpotifyService

final class SpotifyService: ObservableObject {

    static let shared = SpotifyService()
    private init() { loadStoredTokens() }

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiryDate: Date?
    private var pollTimer: Timer?
    private var authCallbackHandler: ((Result<Void, Error>) -> Void)?
    private var debounceWorkItem: DispatchWorkItem?
    private var pollCount204: Int = 0
    private var hasDiagnosed = false
    private var currentPollInterval: TimeInterval = 3.0
    private var rateLimitBackoffTask: DispatchWorkItem?

    // MARK: - Exposed for SpotifySearchService (Priority 1 token reuse)
    //
    // SpotifySearchService checks this first. If the user already has Spotify
    // connected for playback, their token is reused for Apple Music lookups —
    // no second login needed. Returns nil if expired or not authenticated.
    var currentAccessToken: String? {
        guard isAuthenticated,
              let token = accessToken,
              let expiry = tokenExpiryDate,
              Date() < expiry.addingTimeInterval(-60)
        else { return nil }
        return token
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Auth

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        authCallbackHandler = completion
        var components = URLComponents(string: Constants.Spotify.Endpoints.authorize)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: Constants.Spotify.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",  value: Constants.Spotify.redirectURI),
            URLQueryItem(name: "scope",         value: Constants.Spotify.scopes),
            URLQueryItem(name: "show_dialog",   value: "true")
        ]
        guard let url = components.url else {
            completion(.failure(SpotifyError.invalidAuthURL)); return
        }
        print("[Resona] Opening Spotify auth URL: \(url)")
        NSWorkspace.shared.open(url)
    }

    func handleCallback(url: URL) {
        print("[Resona] handleCallback received URL: \(url)")
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            print("[Resona] ERROR: Missing auth code in callback URL")
            authCallbackHandler?(.failure(SpotifyError.missingAuthCode))
            return
        }
        print("[Resona] Got auth code, exchanging for token...")
        exchangeCodeForToken(code: code) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    print("[Resona] Token exchange SUCCESS — starting polling")
                    self?.isAuthenticated = true
                    AppSettings.shared.spotifyConnected = true
                    self?.authCallbackHandler?(.success(()))
                    self?.startPolling()
                case .failure(let e):
                    print("[Resona] Token exchange FAILED: \(e)")
                    self?.authCallbackHandler?(.failure(e))
                }
            }
        }
    }

    func disconnect() {
        stopPolling()
        accessToken = nil; refreshToken = nil; tokenExpiryDate = nil
        currentTrack = nil; playbackState = .stopped; isAuthenticated = false
        AppSettings.shared.spotifyConnected = false
        KeychainManager.delete(forKey: Constants.Spotify.Keychain.accessToken)
        KeychainManager.delete(forKey: Constants.Spotify.Keychain.refreshToken)
        KeychainManager.delete(forKey: Constants.Spotify.Keychain.tokenExpiry)
        print("[Resona] Spotify disconnected, tokens cleared")
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Constants.Spotify.Endpoints.token) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let creds = Data("\(Constants.Spotify.clientID):\(Constants.Spotify.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.httpBody = ["grant_type": "authorization_code",
                        "code": code,
                        "redirect_uri": Constants.Spotify.redirectURI].formEncoded()

        print("[Resona] POSTing to \(Constants.Spotify.Endpoints.token)")

        session.dataTask(with: req) { [weak self] data, response, error in
            if let error { print("[Resona] Token exchange network error: \(error)"); completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse { print("[Resona] Token exchange HTTP status: \(http.statusCode)") }
            guard let data else { completion(.failure(SpotifyError.tokenParseFailed)); return }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
            print("[Resona] Token exchange response: \(raw.prefix(200))")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let expiresIn   = json["expires_in"] as? Int
            else { completion(.failure(SpotifyError.tokenParseFailed)); return }
            let refreshToken = json["refresh_token"] as? String
            self?.storeTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
            completion(.success(()))
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let refresh = refreshToken,
              let url = URL(string: Constants.Spotify.Endpoints.token)
        else { completion(.failure(SpotifyError.noRefreshToken)); return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let creds = Data("\(Constants.Spotify.clientID):\(Constants.Spotify.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.httpBody = ["grant_type": "refresh_token", "refresh_token": refresh].formEncoded()

        print("[Resona] Refreshing access token...")
        session.dataTask(with: req) { [weak self] data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse { print("[Resona] Token refresh HTTP status: \(http.statusCode)") }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let expiresIn   = json["expires_in"] as? Int
            else { completion(.failure(SpotifyError.tokenParseFailed)); return }
            let refreshToken = json["refresh_token"] as? String
            self?.storeTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
            print("[Resona] Token refresh SUCCESS")
            completion(.success(()))
        }.resume()
    }

    // MARK: - Token Storage

    private func storeTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
        self.accessToken = accessToken
        self.tokenExpiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        KeychainManager.save(accessToken, forKey: Constants.Spotify.Keychain.accessToken)
        if let ref = refreshToken {
            self.refreshToken = ref
            KeychainManager.save(ref, forKey: Constants.Spotify.Keychain.refreshToken)
        }
        KeychainManager.save(
            tokenExpiryDate!.timeIntervalSince1970.description,
            forKey: Constants.Spotify.Keychain.tokenExpiry
        )
        print("[Resona] Tokens stored. Expires in \(expiresIn)s")
    }

    private func loadStoredTokens() {
        accessToken  = KeychainManager.read(forKey: Constants.Spotify.Keychain.accessToken)
        refreshToken = KeychainManager.read(forKey: Constants.Spotify.Keychain.refreshToken)
        if let s = KeychainManager.read(forKey: Constants.Spotify.Keychain.tokenExpiry),
           let t = Double(s) { tokenExpiryDate = Date(timeIntervalSince1970: t) }
        isAuthenticated = accessToken != nil
        print("[Resona] loadStoredTokens: accessToken=\(accessToken != nil ? "found" : "nil"), expiry=\(tokenExpiryDate?.description ?? "nil")")
        if isAuthenticated { startPolling() }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        pollCount204 = 0
        hasDiagnosed = false
        let userInterval = TimeInterval(AppSettings.shared.pollingIntervalSeconds)
        currentPollInterval = max(userInterval, 1.0) // floor to 1s
        print("[Resona] Starting Spotify polling every \(currentPollInterval)s")
        schedulePoll(interval: currentPollInterval)
        fetchCurrentlyPlaying()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        rateLimitBackoffTask?.cancel()
        rateLimitBackoffTask = nil
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        currentPollInterval = interval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchCurrentlyPlaying()
        }
    }

    private func backOffPolling(retryAfter: TimeInterval) {
        print("[Resona] ⏸ Rate limited — pausing polls for \(Int(retryAfter))s")
        stopPolling()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isAuthenticated else { return }
            print("[Resona] ▶️ Resuming polling at 5s interval after rate limit")
            DispatchQueue.main.async { self.schedulePoll(interval: 5.0) }
        }
        rateLimitBackoffTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter, execute: task)
    }

    // MARK: - Now Playing

    private func fetchCurrentlyPlaying() {
        ensureValidToken { [weak self] result in
            guard let self else { return }
            if case .failure(let e) = result {
                print("[Resona] ensureValidToken failed: \(e)"); return
            }
            guard let token = self.accessToken else { return }

            var components = URLComponents(string: Constants.Spotify.Endpoints.currentlyPlaying)!
            components.queryItems = [URLQueryItem(name: "additional_types", value: "track,episode")]
            guard let url = components.url else { return }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            self.session.dataTask(with: req) { [weak self] data, response, error in
                guard let self else { return }
                if let error { print("[Resona] Spotify poll network error: \(error)"); return }
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 {
                        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                            .flatMap { TimeInterval($0) } ?? 30.0
                        print("[Resona] ⚠️ Spotify 429 Rate Limited! Retry-After: \(Int(retryAfter))s")
                        DispatchQueue.main.async { self.backOffPolling(retryAfter: retryAfter) }
                        return
                    }
                    if http.statusCode == 204 {
                        self.pollCount204 += 1
                        if self.pollCount204 == 1 || self.pollCount204 % 30 == 0 {
                            print("[Resona] Spotify poll HTTP 204 — count: \(self.pollCount204)")
                        }
                        if self.pollCount204 == 3 && self.currentPollInterval < 5.0 {
                            DispatchQueue.main.async {
                                print("[Resona] Nothing playing — slowing poll to 5s")
                                self.schedulePoll(interval: 5.0)
                            }
                        }
                        if self.pollCount204 == 10 && !self.hasDiagnosed {
                            self.hasDiagnosed = true
                            self.runDiagnostics(token: token)
                        }
                        DispatchQueue.main.async { self.handleNothingPlaying() }
                        return
                    }
                    if self.pollCount204 > 0 && self.currentPollInterval > 3.0 {
                        DispatchQueue.main.async {
                            print("[Resona] Playback detected — speeding poll to 3s")
                            self.schedulePoll(interval: 3.0)
                        }
                    }
                    self.pollCount204 = 0
                    if http.statusCode != 200 { print("[Resona] Spotify poll HTTP \(http.statusCode)") }
                    if http.statusCode == 401 {
                        print("[Resona] 401 — token expired, will refresh on next poll")
                        self.tokenExpiryDate = Date(); return
                    }
                }
                guard let data else { return }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
                    print("[Resona] Spotify poll: failed to parse JSON — \(raw.prefix(200))"); return
                }
                DispatchQueue.main.async { self.handlePlaybackResponse(json) }
            }.resume()
        }
    }

    // MARK: - Diagnostics

    private func runDiagnostics(token: String) {
        print("[Resona] ===== RUNNING SPOTIFY DIAGNOSTICS =====")
        print("[Resona] Token prefix: \(String(token.prefix(12)))...")
        print("[Resona] Token expiry: \(tokenExpiryDate?.description ?? "nil")")

        if let meURL = URL(string: "https://api.spotify.com/v1/me") {
            var meReq = URLRequest(url: meURL)
            meReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: meReq) { data, response, error in
                if let error { print("[Resona] DIAG /v1/me error: \(error)"); return }
                if let http = response as? HTTPURLResponse { print("[Resona] DIAG /v1/me HTTP \(http.statusCode)") }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let displayName = json["display_name"] as? String ?? "<unknown>"
                    let product = json["product"] as? String ?? "<unknown>"
                    print("[Resona] DIAG Account: \(displayName), Product: \(product)")
                }
            }.resume()
        }

        if let playerURL = URL(string: Constants.Spotify.Endpoints.playbackState) {
            var playerReq = URLRequest(url: playerURL)
            playerReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            session.dataTask(with: playerReq) { data, response, error in
                if let error { print("[Resona] DIAG /v1/me/player error: \(error)"); return }
                if let http = response as? HTTPURLResponse {
                    print("[Resona] DIAG /v1/me/player HTTP \(http.statusCode)")
                    if http.statusCode == 204 {
                        print("[Resona] DIAG /v1/me/player also 204 — no active device")
                        print("[Resona] DIAG ⚠️ Make sure Spotify is open and playing on this Mac")
                        return
                    }
                }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let isPlaying = json["is_playing"] as? Bool ?? false
                    let deviceDict = json["device"] as? [String: Any]
                    let deviceName = deviceDict?["name"] as? String ?? "<no device>"
                    print("[Resona] DIAG Player: is_playing=\(isPlaying), device=\(deviceName)")
                }
                print("[Resona] ===== END SPOTIFY DIAGNOSTICS =====")
            }.resume()
        }
    }

    private func handlePlaybackResponse(_ json: [String: Any]) {
        let isPlaying = json["is_playing"] as? Bool ?? false
        playbackState = isPlaying ? .playing : .paused

        guard let item = json["item"] as? [String: Any] else {
            handleNothingPlaying(); return
        }

        let id         = item["id"] as? String ?? UUID().uuidString
        let name       = item["name"] as? String ?? "Unknown"
        let durationMs = item["duration_ms"] as? Int ?? 0
        let progressMs = json["progress_ms"] as? Int ?? 0

        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }.joined(separator: ", ")

        let album = item["album"] as? [String: Any]
        let albumName = album?["name"] as? String ?? "Unknown Album"

        let images = (album?["images"] as? [[String: Any]] ?? [])
            .compactMap { img -> (Int, String)? in
                guard let url = img["url"] as? String, let w = img["width"] as? Int else { return nil }
                return (w, url)
            }.sorted { $0.0 > $1.0 }

        let artworkURL = images.first(where: { $0.0 >= 300 }).flatMap { URL(string: $0.1) }
                      ?? images.first.flatMap { URL(string: $0.1) }

        print("[Resona] Now playing: \(name) by \(artists) | artwork: \(artworkURL?.absoluteString ?? "none")")

        let track = Track(id: id, name: name, artist: artists, album: albumName,
                          artworkURL: artworkURL, canvasURL: nil,
                          durationMs: durationMs, progressMs: progressMs, source: .spotify)

        guard track != currentTrack else { return }

        if AppSettings.shared.showAnimatedWallpapers, let token = accessToken {
            SpotifyCanvasService.shared.fetchCanvasURL(trackID: id, accessToken: token) { [weak self] canvasURL in
                guard let self else { return }
                let finalTrack = canvasURL != nil
                    ? Track(id: id, name: name, artist: artists, album: albumName,
                            artworkURL: artworkURL, canvasURL: canvasURL,
                            durationMs: durationMs, progressMs: progressMs, source: .spotify)
                    : track
                if canvasURL != nil { print("[Resona] Canvas URL attached for \(name)") }
                DispatchQueue.main.async { self.scheduleTrackUpdate(finalTrack) }
            }
        } else {
            scheduleTrackUpdate(track)
        }
    }

    private func handleNothingPlaying() {
        playbackState = .stopped
        debounceWorkItem?.cancel()
        NotificationCenter.default.post(name: .playbackStateDidChange, object: PlaybackState.stopped)
    }

    private func scheduleTrackUpdate(_ track: Track) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            print("[Resona] Track update posted: \(track.name)")
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }

    private func ensureValidToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard accessToken != nil else {
            completion(.failure(SpotifyError.noAccessToken)); return
        }
        guard let expiry = tokenExpiryDate else {
            completion(.success(())); return
        }
        if Date() >= expiry.addingTimeInterval(-60) {
            refreshAccessToken(completion: completion)
        } else {
            completion(.success(()))
        }
    }
}