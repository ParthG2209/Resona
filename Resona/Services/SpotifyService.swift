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
// NOTE: All JSON parsing uses [String: Any] dictionaries to avoid
// Swift 6 @MainActor isolation issues with Decodable structs.

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
    private let session = URLSession.shared

    // MARK: - Auth

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        authCallbackHandler = completion
        var components = URLComponents(string: Constants.Spotify.Endpoints.authorize)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: Constants.Spotify.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",  value: Constants.Spotify.redirectURI),
            URLQueryItem(name: "scope",         value: Constants.Spotify.scopes),
            URLQueryItem(name: "show_dialog",   value: "false")
        ]
        guard let url = components.url else {
            completion(.failure(SpotifyError.invalidAuthURL)); return
        }
        NSWorkspace.shared.open(url)
    }

    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { authCallbackHandler?(.failure(SpotifyError.missingAuthCode)); return }
        exchangeCodeForToken(code: code) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.isAuthenticated = true
                    AppSettings.shared.spotifyConnected = true
                    self?.authCallbackHandler?(.success(()))
                    self?.startPolling()
                case .failure(let e): self?.authCallbackHandler?(.failure(e))
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
        session.dataTask(with: req) { [weak self] data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        session.dataTask(with: req) { [weak self] data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let expiresIn   = json["expires_in"] as? Int
            else { completion(.failure(SpotifyError.tokenParseFailed)); return }
            let refreshToken = json["refresh_token"] as? String
            self?.storeTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
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
    }

    private func loadStoredTokens() {
        accessToken  = KeychainManager.read(forKey: Constants.Spotify.Keychain.accessToken)
        refreshToken = KeychainManager.read(forKey: Constants.Spotify.Keychain.refreshToken)
        if let s = KeychainManager.read(forKey: Constants.Spotify.Keychain.tokenExpiry),
           let t = Double(s) { tokenExpiryDate = Date(timeIntervalSince1970: t) }
        isAuthenticated = accessToken != nil
        if isAuthenticated { startPolling() }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        let interval = TimeInterval(AppSettings.shared.pollingIntervalSeconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchCurrentlyPlaying()
        }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    // MARK: - Now Playing

    private func fetchCurrentlyPlaying() {
        ensureValidToken { [weak self] result in
            guard case .success = result,
                  let token = self?.accessToken,
                  let url = URL(string: Constants.Spotify.Endpoints.currentlyPlaying) else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            self?.session.dataTask(with: req) { data, response, error in
                if let error { Logger.error("Spotify poll: \(error)", category: .spotify); return }
                if let http = response as? HTTPURLResponse, http.statusCode == 204 {
                    DispatchQueue.main.async { self?.handleNothingPlaying() }; return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                DispatchQueue.main.async { self?.handlePlaybackResponse(json) }
            }.resume()
        }
    }

    private func handlePlaybackResponse(_ json: [String: Any]) {
        let isPlaying = json["is_playing"] as? Bool ?? false
        playbackState = isPlaying ? .playing : .paused

        guard let item = json["item"] as? [String: Any] else { handleNothingPlaying(); return }

        let id         = item["id"] as? String ?? UUID().uuidString
        let name       = item["name"] as? String ?? "Unknown"
        let durationMs = item["duration_ms"] as? Int ?? 0
        let progressMs = json["progress_ms"] as? Int ?? 0

        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ")

        let album = item["album"] as? [String: Any]
        let albumName = album?["name"] as? String ?? "Unknown Album"

        let images = (album?["images"] as? [[String: Any]] ?? [])
            .compactMap { img -> (Int, String)? in
                guard let url = img["url"] as? String,
                      let w   = img["width"] as? Int else { return nil }
                return (w, url)
            }
            .sorted { $0.0 > $1.0 }

        let artworkURL = images.first(where: { $0.0 >= 300 }).flatMap { URL(string: $0.1) }
                      ?? images.first.flatMap { URL(string: $0.1) }

        let track = Track(
            id: id, name: name, artist: artists, album: albumName,
            artworkURL: artworkURL, canvasURL: nil,
            durationMs: durationMs, progressMs: progressMs, source: .spotify
        )
        if track != currentTrack { scheduleTrackUpdate(track) }
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
            Logger.info("Spotify track: \(track.name) – \(track.artist)", category: .spotify)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Wallpaper.debounceInterval, execute: item)
    }

    private func ensureValidToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let expiry = tokenExpiryDate else {
            completion(.failure(SpotifyError.noAccessToken)); return
        }
        if Date() >= expiry.addingTimeInterval(-60) { refreshAccessToken(completion: completion) }
        else { completion(.success(())) }
    }
}
