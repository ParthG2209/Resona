import Foundation
import Combine

// MARK: - SpotifyService

/// Handles Spotify OAuth 2.0 authentication and now-playing polling.
final class SpotifyService: ObservableObject {

    static let shared = SpotifyService()
    private init() { loadStoredTokens() }

    // MARK: - Published State

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentTrack: Track?
    @Published private(set) var playbackState: PlaybackState = .stopped

    // MARK: - Private Properties

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiryDate: Date?

    private var pollTimer: Timer?
    private var authCallbackHandler: ((Result<Void, Error>) -> Void)?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSeenTrackID: String?

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
            completion(.failure(SpotifyError.invalidAuthURL))
            return
        }

        NSWorkspace.shared.open(url)
        Logger.info("Opened Spotify auth URL in browser", category: .spotify)
    }

    /// Called by the app's URL scheme handler when Spotify redirects back.
    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            authCallbackHandler?(.failure(SpotifyError.missingAuthCode))
            return
        }

        exchangeCodeForToken(code: code) { [weak self] result in
            switch result {
            case .success:
                self?.isAuthenticated = true
                AppSettings.shared.spotifyConnected = true
                self?.authCallbackHandler?(.success(()))
                self?.startPolling()
            case .failure(let error):
                self?.authCallbackHandler?(.failure(error))
            }
        }
    }

    func disconnect() {
        stopPolling()
        accessToken = nil
        refreshToken = nil
        tokenExpiryDate = nil
        currentTrack = nil
        playbackState = .stopped
        isAuthenticated = false
        AppSettings.shared.spotifyConnected = false

        KeychainManager.delete(forKey: Constants.Spotify.Keychain.accessToken)
        KeychainManager.delete(forKey: Constants.Spotify.Keychain.refreshToken)
        KeychainManager.delete(forKey: Constants.Spotify.Keychain.tokenExpiry)
        Logger.info("Spotify disconnected", category: .spotify)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Constants.Spotify.Endpoints.token) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic auth header
        let credentials = "\(Constants.Spotify.clientID):\(Constants.Spotify.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let body = [
            "grant_type":   "authorization_code",
            "code":          code,
            "redirect_uri":  Constants.Spotify.redirectURI
        ].formEncoded()
        request.httpBody = body

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            else {
                completion(.failure(SpotifyError.tokenParseFailed))
                return
            }
            self?.storeTokens(json)
            completion(.success(()))
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let refresh = refreshToken,
              let url = URL(string: Constants.Spotify.Endpoints.token)
        else {
            completion(.failure(SpotifyError.noRefreshToken))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(Constants.Spotify.clientID):\(Constants.Spotify.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        request.httpBody = [
            "grant_type":    "refresh_token",
            "refresh_token":  refresh
        ].formEncoded()

        session.dataTask(with: request) { [weak self] data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data,
                  let json = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            else {
                completion(.failure(SpotifyError.tokenParseFailed))
                return
            }
            self?.storeTokens(json)
            completion(.success(()))
        }.resume()
    }

    // MARK: - Token Storage

    private func storeTokens(_ response: SpotifyTokenResponse) {
        accessToken = response.access_token
        tokenExpiryDate = Date().addingTimeInterval(TimeInterval(response.expires_in))

        KeychainManager.save(response.access_token, forKey: Constants.Spotify.Keychain.accessToken)
        if let refresh = response.refresh_token {
            refreshToken = refresh
            KeychainManager.save(refresh, forKey: Constants.Spotify.Keychain.refreshToken)
        }
        KeychainManager.save(
            tokenExpiryDate!.timeIntervalSince1970.description,
            forKey: Constants.Spotify.Keychain.tokenExpiry
        )
        Logger.info("Spotify tokens stored", category: .spotify)
    }

    private func loadStoredTokens() {
        accessToken  = KeychainManager.read(forKey: Constants.Spotify.Keychain.accessToken)
        refreshToken = KeychainManager.read(forKey: Constants.Spotify.Keychain.refreshToken)

        if let expiryStr = KeychainManager.read(forKey: Constants.Spotify.Keychain.tokenExpiry),
           let expiryTs = Double(expiryStr) {
            tokenExpiryDate = Date(timeIntervalSince1970: expiryTs)
        }

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
        Logger.info("Spotify polling started (interval: \(interval)s)", category: .spotify)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Now-Playing Fetch

    private func fetchCurrentlyPlaying() {
        ensureValidToken { [weak self] result in
            guard case .success = result, let token = self?.accessToken else { return }

            guard let url = URL(string: Constants.Spotify.Endpoints.currentlyPlaying) else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            self?.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    Logger.error("Spotify poll error: \(error.localizedDescription)", category: .spotify)
                    return
                }

                // 204 = nothing playing
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
                    DispatchQueue.main.async { self?.handleNothingPlaying() }
                    return
                }

                guard let data = data,
                      let response = try? JSONDecoder().decode(SpotifyCurrentlyPlayingResponse.self, from: data)
                else { return }

                DispatchQueue.main.async {
                    self?.handlePlaybackResponse(response)
                }
            }.resume()
        }
    }

    private func handlePlaybackResponse(_ response: SpotifyCurrentlyPlayingResponse) {
        let newState: PlaybackState = response.is_playing ? .playing : .paused

        playbackState = newState

        guard let item = response.item else {
            handleNothingPlaying()
            return
        }

        let artworkURL = item.album.images
            .filter { ($0.width ?? 0) >= 300 }
            .sorted { ($0.width ?? 0) > ($1.width ?? 0) }
            .first
            .flatMap { URL(string: $0.url) }

        let track = Track(
            id:           item.id,
            name:         item.name,
            artist:       item.artists.map(\.name).joined(separator: ", "),
            album:        item.album.name,
            artworkURL:   artworkURL,
            canvasURL:    nil,   // Canvas support – Phase 3
            durationMs:   item.duration_ms,
            progressMs:   response.progress_ms ?? 0,
            source:       .spotify
        )

        // Debounce rapid skips
        if track != currentTrack {
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.currentTrack = track
            NotificationCenter.default.post(name: .trackDidChange, object: track)
            Logger.info("Track changed: \(track.name) – \(track.artist)", category: .spotify)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.Wallpaper.debounceInterval,
            execute: workItem
        )
    }

    // MARK: - Token Validation

    private func ensureValidToken(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let expiry = tokenExpiryDate else {
            completion(.failure(SpotifyError.noAccessToken))
            return
        }

        // Refresh if within 60 seconds of expiry
        if Date() >= expiry.addingTimeInterval(-60) {
            refreshAccessToken(completion: completion)
        } else {
            completion(.success(()))
        }
    }
}

// MARK: - Spotify API Response Models

private struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String
}

private struct SpotifyCurrentlyPlayingResponse: Decodable {
    let is_playing: Bool
    let progress_ms: Int?
    let item: SpotifyTrackItem?
}

private struct SpotifyTrackItem: Decodable {
    let id: String
    let name: String
    let duration_ms: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
}

private struct SpotifyArtist: Decodable {
    let name: String
}

private struct SpotifyAlbum: Decodable {
    let name: String
    let images: [SpotifyImage]
}

private struct SpotifyImage: Decodable {
    let url: String
    let width: Int?
    let height: Int?
}

// MARK: - Errors

enum SpotifyError: LocalizedError {
    case invalidAuthURL
    case missingAuthCode
    case tokenParseFailed
    case noRefreshToken
    case noAccessToken

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL:    return "Could not construct Spotify auth URL."
        case .missingAuthCode:   return "Spotify did not return an auth code."
        case .tokenParseFailed:  return "Failed to parse Spotify token response."
        case .noRefreshToken:    return "No refresh token stored."
        case .noAccessToken:     return "No access token available."
        }
    }
}

// MARK: - Dictionary Form Encoding Helper

private extension Dictionary where Key == String, Value == String {
    func formEncoded() -> Data? {
        map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}
