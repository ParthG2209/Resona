import Foundation
import AppKit

// MARK: - SpotifyLookupResult

struct SpotifyLookupResult {
    let artworkURL: URL
    let trackID: String
    var canvasURL: URL?
}

// MARK: - SpotifySearchService
//
// Provides Spotify catalog lookups (artwork + Canvas) for Apple Music users.
//
// ── Why not Client Credentials? ──────────────────────────────────────────────
// Client Credentials issues a single app-level token shared by every user.
// Rate limits are applied per app ID, so at scale every Apple Music user
// exhausts the same bucket → HTTP 429s across the board. (FUTURE_SCOPE §3.1)
//
// ── Token priority ───────────────────────────────────────────────────────────
// 1. SpotifySearchService has its own stored Authorization Code token.
//    This is always preferred — it has user-read-private scope which is needed
//    for accurate market-aware search results.
// 2. SpotifyService has a valid playback token AND search succeeds with it.
//    Used as a convenience when the user already connected Spotify for playback,
//    so they don't need a second login. However if it returns 403 (missing
//    user-read-private scope), we do NOT fall back — we return nil and let
//    the UI prompt for a proper link.
//
// ── Why market=from_token was removed ────────────────────────────────────────
// market=from_token requires user-read-private scope. The Spotify playback token
// uses scopes user-read-currently-playing + user-read-playback-state + user-read-email,
// none of which satisfy market=from_token → HTTP 403 on every search.
// We now omit the market parameter entirely; Spotify returns global results.

final class SpotifySearchService {

    static let shared = SpotifySearchService()
    private init() {
        loadStoredTokens()
    }

    // MARK: - Auth State

    private(set) var isLinked: Bool {
        get { AppSettings.shared.spotifyLinkedForAppleMusic }
        set { AppSettings.shared.spotifyLinkedForAppleMusic = newValue }
    }

    private(set) var isHandlingSearchAuth = false
    private var authCompletion: ((Result<Void, Error>) -> Void)?

    // MARK: - Token Storage (separate Keychain keys from SpotifyService)

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    private enum KeychainKeys {
        static let accessToken  = "resona.spotifysearch.accessToken"
        static let refreshToken = "resona.spotifysearch.refreshToken"
        static let tokenExpiry  = "resona.spotifysearch.tokenExpiry"
    }

    // user-read-private is required to avoid 403s on search with market=from_token.
    // We don't use market=from_token anymore, but this scope also ensures the token
    // is a proper non-anonymous per-user token with its own rate limit bucket.
    private let scope = "user-read-private"

    // MARK: - URLSession

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public: Connect

    func connectForAppleMusic(completion: @escaping (Result<Void, Error>) -> Void) {
        authCompletion = completion
        isHandlingSearchAuth = true

        var components = URLComponents(string: Constants.Spotify.Endpoints.authorize)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: Constants.Spotify.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",  value: Constants.Spotify.redirectURI),
            URLQueryItem(name: "scope",         value: scope),
            URLQueryItem(name: "show_dialog",   value: "false")
        ]

        guard let url = components.url else {
            isHandlingSearchAuth = false
            completion(.failure(SpotifyError.invalidAuthURL))
            return
        }

        print("[Resona] SpotifySearch: Opening OAuth for Apple Music link")
        NSWorkspace.shared.open(url)
    }

    func handleCallback(url: URL) {
        isHandlingSearchAuth = false

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            print("[Resona] SpotifySearch: Missing auth code in callback")
            authCompletion?(.failure(SpotifyError.missingAuthCode))
            authCompletion = nil
            return
        }

        exchangeCodeForToken(code: code) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.isLinked = true
                    AppSettings.shared.spotifyLinkedForAppleMusic = true
                    print("[Resona] SpotifySearch: ✅ Apple Music → Spotify link successful")
                case .failure(let e):
                    print("[Resona] SpotifySearch: Token exchange failed: \(e)")
                }
                self.authCompletion?(result)
                self.authCompletion = nil
            }
        }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        isLinked = false
        AppSettings.shared.spotifyLinkedForAppleMusic = false
        KeychainManager.delete(forKey: KeychainKeys.accessToken)
        KeychainManager.delete(forKey: KeychainKeys.refreshToken)
        KeychainManager.delete(forKey: KeychainKeys.tokenExpiry)
        print("[Resona] SpotifySearch: Apple Music Spotify link removed")
    }

    // MARK: - Public: Lookup

    func lookup(title: String, artist: String) async -> SpotifyLookupResult? {
        guard let token = await resolveToken() else {
            print("[Resona] SpotifySearch: No valid user token — Apple Music user needs to link Spotify")
            return nil
        }

        guard var result = await searchTrack(title: title, artist: artist, token: token) else {
            print("[Resona] SpotifySearch: No Spotify match for '\(title)' by '\(artist)'")
            return nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotifyCanvasService.shared.fetchCanvasURL(
                trackID: result.trackID,
                accessToken: token
            ) { canvasURL in
                result.canvasURL = canvasURL
                continuation.resume()
            }
        }

        return result
    }

    // MARK: - Token Resolution
    //
    // Priority 1: This service's own token (has user-read-private, full search support)
    // Priority 2: SpotifyService playback token (convenience — no second login needed,
    //             but search is attempted without market parameter to avoid 403)
    //
    // If Priority 2 returns 403, we return nil. The 403 is specifically logged so
    // it's clear the user needs to link Spotify via connectForAppleMusic().

    private func resolveToken() async -> String? {
        // Priority 1: use own token (correct scopes, own rate limit bucket)
        if let ownToken = await ensureOwnToken() {
            return ownToken
        }

        // Priority 2: reuse Spotify playback token as convenience
        // This works as long as the user's Spotify account has access to the track.
        // We do NOT use market=from_token with this token (it lacks user-read-private).
        if let playbackToken = SpotifyService.shared.currentAccessToken {
            print("[Resona] SpotifySearch: No own token — trying playback token (no market param)")
            return playbackToken
        }

        return nil
    }

    private func ensureOwnToken() async -> String? {
        guard accessToken != nil else { return nil }

        if let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) {
            return accessToken
        }

        return await withCheckedContinuation { continuation in
            refreshAccessToken { [weak self] result in
                switch result {
                case .success:
                    continuation.resume(returning: self?.accessToken)
                case .failure(let e):
                    print("[Resona] SpotifySearch: Token refresh failed: \(e)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: Constants.Spotify.Endpoints.token) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let creds = Data("\(Constants.Spotify.clientID):\(Constants.Spotify.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.httpBody = [
            "grant_type":   "authorization_code",
            "code":         code,
            "redirect_uri": Constants.Spotify.redirectURI
        ].formEncoded()

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int
            else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "<unreadable>"
                print("[Resona] SpotifySearch: Token exchange parse failed: \(raw.prefix(200))")
                completion(.failure(SpotifyError.tokenParseFailed))
                return
            }
            self.storeTokens(accessToken: token, refreshToken: json["refresh_token"] as? String, expiresIn: expiresIn)
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
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int
            else { completion(.failure(SpotifyError.tokenParseFailed)); return }
            self.storeTokens(accessToken: token, refreshToken: json["refresh_token"] as? String, expiresIn: expiresIn)
            completion(.success(()))
        }.resume()
    }

    // MARK: - Token Persistence

    private func storeTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
        self.accessToken = accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        KeychainManager.save(accessToken, forKey: KeychainKeys.accessToken)
        KeychainManager.save(tokenExpiry!.timeIntervalSince1970.description, forKey: KeychainKeys.tokenExpiry)
        if let rt = refreshToken {
            self.refreshToken = rt
            KeychainManager.save(rt, forKey: KeychainKeys.refreshToken)
        }
    }

    private func loadStoredTokens() {
        accessToken  = KeychainManager.read(forKey: KeychainKeys.accessToken)
        refreshToken = KeychainManager.read(forKey: KeychainKeys.refreshToken)
        if let s = KeychainManager.read(forKey: KeychainKeys.tokenExpiry), let t = Double(s) {
            tokenExpiry = Date(timeIntervalSince1970: t)
        }
        if accessToken != nil {
            isLinked = true
            AppSettings.shared.spotifyLinkedForAppleMusic = true
        }
        print("[Resona] SpotifySearch: loadStoredTokens — linked=\(isLinked)")
    }

    // MARK: - Track Search

    private func searchTrack(title: String, artist: String, token: String) async -> SpotifyLookupResult? {
        let primaryArtist = extractPrimaryArtist(from: artist)

        // Strategy 1: Strict field search
        if let result = await executeSearch(
            query: "track:\"\(escapeQuery(title))\" artist:\"\(escapeQuery(primaryArtist))\"",
            expectedArtist: artist, token: token, strategy: "strict"
        ) { return result }

        // Strategy 2: Relaxed plain-text search
        let cleanTitle  = cleanForSearch(title)
        let cleanArtist = cleanForSearch(primaryArtist)
        if let result = await executeSearch(
            query: "\(cleanTitle) \(cleanArtist)",
            expectedArtist: artist, token: token, strategy: "relaxed"
        ) { return result }

        // Strategy 3: Title only — last resort
        if let result = await executeSearch(
            query: cleanTitle,
            expectedArtist: artist, token: token, strategy: "title-only"
        ) { return result }

        return nil
    }

    private func executeSearch(
        query: String,
        expectedArtist: String,
        token: String,
        strategy: String
    ) async -> SpotifyLookupResult? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q",     value: query),
            URLQueryItem(name: "type",  value: "track"),
            URLQueryItem(name: "limit", value: "5")
            // market=from_token intentionally omitted — requires user-read-private scope.
            // The playback token does not have this scope → HTTP 403.
            // Omitting market returns global results which is correct for our use case.
        ]
        guard let url = components.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: req)

            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    break // continue parsing below
                case 401:
                    // Token expired — wipe own token so next call refreshes
                    if token == accessToken {
                        accessToken = nil
                        tokenExpiry = nil
                    }
                    print("[Resona] SpotifySearch: 401 — token expired [\(strategy)]")
                    return nil
                case 403:
                    // 403 almost always means the token lacks required scope.
                    // With the playback token this is expected if market=from_token
                    // was mistakenly included. Since we now omit it, a 403 here
                    // means something else is wrong — log the response body for diagnosis.
                    let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
                    print("[Resona] SpotifySearch: 403 [\(strategy)] — response: \(raw.prefix(300))")
                    print("[Resona] SpotifySearch: 403 usually means wrong/insufficient token scope.")
                    print("[Resona] SpotifySearch: If using playback token, user should link Spotify via connectForAppleMusic().")
                    return nil
                case 429:
                    print("[Resona] SpotifySearch: 429 rate limited [\(strategy)]")
                    return nil
                default:
                    let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
                    print("[Resona] SpotifySearch: HTTP \(http.statusCode) [\(strategy)]: \(raw.prefix(200))")
                    return nil
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [String: Any],
                  let items = tracks["items"] as? [[String: Any]],
                  !items.isEmpty
            else {
                print("[Resona] SpotifySearch: No items in response [\(strategy)]")
                return nil
            }

            for item in items {
                guard let trackID = item["id"] as? String,
                      let album   = item["album"] as? [String: Any]
                else { continue }

                let resultArtists = (item["artists"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String }

                guard artistMatches(expected: expectedArtist, candidates: resultArtists) else {
                    print("[Resona] SpotifySearch: [\(strategy)] skipping '\(resultArtists.joined(separator: ", "))' — artist mismatch")
                    continue
                }

                let images = (album["images"] as? [[String: Any]] ?? [])
                    .compactMap { img -> (Int, String)? in
                        guard let u = img["url"] as? String, let w = img["width"] as? Int else { return nil }
                        return (w, u)
                    }
                    .sorted { $0.0 > $1.0 }

                guard let best = images.first, let artworkURL = URL(string: best.1) else { continue }

                let trackName = item["name"] as? String ?? ""
                print("[Resona] SpotifySearch: ✅ [\(strategy)] '\(trackName)' by \(resultArtists.joined(separator: ", ")) — \(best.0)px")
                return SpotifyLookupResult(artworkURL: artworkURL, trackID: trackID, canvasURL: nil)
            }

            print("[Resona] SpotifySearch: [\(strategy)] all \(items.count) results failed artist validation")

        } catch {
            print("[Resona] SpotifySearch: Network error [\(strategy)]: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Artist Matching

    private func artistMatches(expected: String, candidates: [String]) -> Bool {
        let expParts  = splitArtists(expected).map  { normalize($0) }
        let candParts = candidates.flatMap { splitArtists($0) }.map { normalize($0) }
        for exp in expParts {
            for cand in candParts {
                if exp == cand { return true }
                if exp.count > 4 && (cand.contains(exp) || exp.contains(cand)) { return true }
            }
        }
        return false
    }

    private func splitArtists(_ artist: String) -> [String] {
        var parts = [artist]
        for sep in [", ", " & ", " x ", " X ", " feat. ", " ft. ", " featuring ", " / "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - String Utilities

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanForSearch(_ text: String) -> String {
        var s = text
        for pattern in ["(feat.", "(ft.", "(featuring", "[feat.", "[ft.", " feat.", " ft."] {
            if let r = s.range(of: pattern, options: .caseInsensitive) {
                let close: Character = pattern.hasPrefix("(") ? ")" : pattern.hasPrefix("[") ? "]" : "\0"
                if close != "\0", let cr = s[r.upperBound...].firstIndex(of: close) {
                    s.removeSubrange(r.lowerBound...cr)
                } else {
                    s = String(s[..<r.lowerBound])
                }
            }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        s = s.unicodeScalars.filter { allowed.contains($0) }.map { String($0) }.joined()
        return s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func escapeQuery(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func extractPrimaryArtist(from artist: String) -> String {
        splitArtists(artist).max(by: { $0.count < $1.count }) ?? artist
    }
}

// MARK: - Dictionary form-encoding

private extension Dictionary where Key == String, Value == String {
    func formEncoded() -> Data? {
        map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
    }
}