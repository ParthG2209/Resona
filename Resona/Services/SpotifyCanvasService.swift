import Foundation
import CommonCrypto

// MARK: - SpotifyCanvasService
/// Fetches Spotify Canvas (looping video) URLs using the unofficial internal API.
/// Uses sp_dc cookie + TOTP → internal bearer token → protobuf Canvas endpoint.
///
/// ⚠️ This uses undocumented Spotify endpoints. It may stop working at any time.

final class SpotifyCanvasService {

    static let shared = SpotifyCanvasService()
    private init() {}

    // MARK: - Endpoints
    private let tokenEndpoint = "https://open.spotify.com/api/token"
    private let serverTimeEndpoint = "https://open.spotify.com/api/server-time"
    private let secretsURL = "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json"
    private let canvasEndpoint = "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"

    // MARK: - State
    private var internalToken: String?
    private var tokenExpiry: Date?
    private var cache: [String: String] = [:]  // trackID → canvasURL (or "" for no canvas)
    private var tokenFetchInProgress = false
    private var pendingTokenCallbacks: [(String?) -> Void] = []

    // TOTP state
    private var totpSecret: Data?
    private var totpVersion: String?
    private var lastSecretFetch: Date?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        // CRITICAL: Disable automatic cookie handling.
        // Without this, URLSession stores cookies from responses (e.g. server-time)
        // and sends them alongside our manual Cookie header, breaking auth.
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    func fetchCanvasURL(trackID: String, accessToken: String, completion: @escaping (URL?) -> Void) {
        let spDc = AppSettings.shared.spotifySpDcCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spDc.isEmpty else {
            print("[Resona] Canvas: No sp_dc cookie configured. Set it in Settings > Advanced.")
            completion(nil)
            return
        }

        if let cached = cache[trackID] {
            completion(cached.isEmpty ? nil : URL(string: cached))
            return
        }

        ensureInternalToken(spDc: spDc) { [weak self] token in
            guard let self, let token else {
                print("[Resona] Canvas: Failed to obtain internal token")
                completion(nil)
                return
            }
            self.fetchCanvas(trackID: trackID, token: token, completion: completion)
        }
    }

    func clearCache() {
        cache.removeAll()
        internalToken = nil
        tokenExpiry = nil
    }

    // MARK: - Internal Token (sp_dc + TOTP → bearer)

    private func ensureInternalToken(spDc: String, completion: @escaping (String?) -> Void) {
        if let token = internalToken, let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-60) {
            completion(token)
            return
        }

        pendingTokenCallbacks.append(completion)
        guard !tokenFetchInProgress else { return }
        tokenFetchInProgress = true

        print("[Resona] Canvas: Starting TOTP-based token exchange...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Step 1: Ensure we have TOTP secrets
            self.ensureTOTPSecrets()

            guard self.totpSecret != nil, let totpVer = self.totpVersion else {
                print("[Resona] Canvas: Failed to get TOTP secrets")
                self.flushTokenCallbacks(nil)
                return
            }

            // Step 2: Get Spotify server time
            let serverTimeMs = self.fetchServerTime(spDc: spDc)

            // Step 3: Generate TOTP codes
            // Local TOTP uses current time in ms directly
            // Server TOTP uses serverTimeMs / 30 (matches Spotify's JS: Math.floor(serverTime / 30))
            let localTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
            let localTotp = self.generateTOTP(timestampMs: localTimeMs)
            let serverTotp = self.generateTOTP(timestampMs: serverTimeMs / 30)

            print("[Resona] Canvas: TOTP generated — ver=\(totpVer), local=\(localTotp), server=\(serverTotp)")

            // Debug: verify cookie
            print("[Resona] Canvas: sp_dc length=\(spDc.count), first10=\(String(spDc.prefix(10))), last10=\(String(spDc.suffix(10)))")

            // Step 4: Exchange for token via curl (proven to work from terminal)
            let fullURL = "\(self.tokenEndpoint)?reason=init&productType=web_player&totp=\(localTotp)&totpVer=\(totpVer)&totpServer=\(serverTotp)"

            let curlArgs = [
                "-s",
                "--max-time", "10",
                "-H", "Cookie: sp_dc=\(spDc)",
                "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36",
                "-H", "Origin: https://open.spotify.com",
                "-H", "Referer: https://open.spotify.com/",
                fullURL
            ]

            // Debug: print reproducible curl command
            let debugCmd = curlArgs.map { arg in
                arg.contains(" ") || arg.contains("=") ? "\"\(arg)\"" : arg
            }.joined(separator: " ")
            print("[Resona] Canvas: curl /usr/bin/curl \(debugCmd)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = curlArgs

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("[Resona] Canvas: curl error: \(error.localizedDescription)")
                self.flushTokenCallbacks(nil)
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0, !data.isEmpty else {
                print("[Resona] Canvas: curl failed (exit=\(process.terminationStatus))")
                self.flushTokenCallbacks(nil)
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? "<unreadable>"
            print("[Resona] Canvas: curl response (first 200): \(String(raw.prefix(200)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["accessToken"] as? String else {
                print("[Resona] Canvas: Token parse error: \(String(raw.prefix(300)))")
                self.flushTokenCallbacks(nil)
                return
            }

            let isAnonymous = json["isAnonymous"] as? Bool ?? true
            if isAnonymous {
                print("[Resona] Canvas: sp_dc cookie is invalid (anonymous). Update in Settings > Advanced.")
                self.flushTokenCallbacks(nil)
                return
            }

            let expiryMs = json["accessTokenExpirationTimestampMs"] as? Int64
                        ?? (json["accessTokenExpirationTimestampMs"] as? Double).map { Int64($0) }
                        ?? 0
            let expiry = Date(timeIntervalSince1970: Double(expiryMs) / 1000.0)

            self.internalToken = token
            self.tokenExpiry = expiry
            print("[Resona] ✅ Canvas internal token obtained, expires: \(expiry)")
            self.flushTokenCallbacks(token)
        }
    }

    private func flushTokenCallbacks(_ token: String?) {
        tokenFetchInProgress = false
        let callbacks = pendingTokenCallbacks
        pendingTokenCallbacks.removeAll()
        for cb in callbacks { cb(token) }
    }

    // MARK: - TOTP Secrets

    private func ensureTOTPSecrets() {
        // Refresh every hour
        if let last = lastSecretFetch, Date().timeIntervalSince(last) < 3600, totpSecret != nil {
            return
        }

        print("[Resona] Canvas: Fetching TOTP secrets...")

        let sem = DispatchSemaphore(value: 0)
        var fetchedData: Data?

        session.dataTask(with: URL(string: secretsURL)!) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                fetchedData = data
            } else if let error {
                print("[Resona] Canvas: Secrets fetch error: \(error.localizedDescription)")
            }
            sem.signal()
        }.resume()

        sem.wait()

        guard let data = fetchedData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Resona] Canvas: Failed to parse secrets JSON, using fallback")
            useFallbackSecret()
            return
        }

        // Find newest version
        let versions = json.keys.compactMap { Int($0) }.sorted()
        guard let newest = versions.last else {
            useFallbackSecret()
            return
        }

        let version = String(newest)

        // Get the array of integers for this version
        guard let secretArray = json[version] as? [Int] else {
            print("[Resona] Canvas: Secret array not found for version \(version)")
            useFallbackSecret()
            return
        }

        // XOR transform: value ^ ((index % 33) + 9)
        let mapped = secretArray.enumerated().map { (index, value) in
            value ^ ((index % 33) + 9)
        }

        // Join as string of digits, then use as UTF-8 bytes (matching JS behavior)
        let joinedString = mapped.map { String($0) }.joined()
        totpSecret = Data(joinedString.utf8)
        totpVersion = version
        lastSecretFetch = Date()

        // Debug: print hex to compare with Python output
        let hexStr = totpSecret!.map { String(format: "%02x", $0) }.joined()
        print("[Resona] Canvas: TOTP secrets updated to version \(version), secret length=\(totpSecret!.count)")
        print("[Resona] Canvas: Secret hex (first 40): \(String(hexStr.prefix(40)))...")
    }

    private func useFallbackSecret() {
        let fallbackData = [99, 111, 47, 88, 49, 56, 118, 65, 52, 67, 50, 104, 117, 101, 55, 94, 95, 75, 94, 49, 69, 36, 85, 64, 74, 60]
        let mapped = fallbackData.enumerated().map { (index, value) in
            value ^ ((index % 33) + 9)
        }
        let joinedString = mapped.map { String($0) }.joined()
        let hexSecret = joinedString.utf8.map { String(format: "%02x", $0) }.joined()

        totpSecret = hexToData(hexSecret)
        totpVersion = "19"
        print("[Resona] Canvas: Using fallback TOTP secret (may not work)")
    }

    // MARK: - TOTP Generation (RFC 6238 / HOTP with SHA1)

    private func generateTOTP(timestampMs: Int64) -> String {
        guard let secret = totpSecret else { return "000000" }

        let period: Int64 = 30
        let counter = timestampMs / 1000 / period

        // Convert counter to 8-byte big-endian
        var counterBE = counter.bigEndian
        let counterData = Data(bytes: &counterBE, count: 8)

        // HMAC-SHA1
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        secret.withUnsafeBytes { secretPtr in
            counterData.withUnsafeBytes { counterPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    secretPtr.baseAddress, secret.count,
                    counterPtr.baseAddress, counterData.count,
                    &hmac
                )
            }
        }

        // Dynamic truncation
        let offset = Int(hmac[19] & 0x0F)
        let code = (Int(hmac[offset]) & 0x7F) << 24
                 | (Int(hmac[offset + 1]) & 0xFF) << 16
                 | (Int(hmac[offset + 2]) & 0xFF) << 8
                 | (Int(hmac[offset + 3]) & 0xFF)

        let otp = code % 1_000_000
        return String(format: "%06d", otp)
    }

    // MARK: - Server Time

    private func fetchServerTime(spDc: String) -> Int64 {
        let sem = DispatchSemaphore(value: 0)
        var serverTimeMs = Int64(Date().timeIntervalSince1970 * 1000) // fallback

        var req = URLRequest(url: URL(string: serverTimeEndpoint)!)
        req.setValue("sp_dc=\(spDc)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        req.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")

        session.dataTask(with: req) { data, response, error in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let st = json["serverTime"] as? Double {
                serverTimeMs = Int64(st * 1000)
                print("[Resona] Canvas: Server time = \(st)s")
            } else {
                print("[Resona] Canvas: Server time fetch failed, using local time")
            }
            sem.signal()
        }.resume()

        sem.wait()
        return serverTimeMs
    }

    // MARK: - Canvas Fetch (protobuf)

    private func fetchCanvas(trackID: String, token: String, completion: @escaping (URL?) -> Void) {
        let trackURI = "spotify:track:\(trackID)"
        let requestBody = ProtobufEncoder.encodeCanvasRequest(trackURI: trackURI)

        guard let url = URL(string: canvasEndpoint) else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = requestBody
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue("application/protobuf", forHTTPHeaderField: "Accept")
        req.setValue("Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)", forHTTPHeaderField: "User-Agent")
        req.setValue("ios", forHTTPHeaderField: "App-Platform")

        session.dataTask(with: req) { [weak self] data, response, error in
            if let error {
                print("[Resona] Canvas API error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            if let http = response as? HTTPURLResponse {
                print("[Resona] Canvas API HTTP \(http.statusCode)")
                if http.statusCode != 200 {
                    if let data {
                        let raw = String(data: data, encoding: .utf8) ?? ""
                        print("[Resona] Canvas API response: \(raw.prefix(200))")
                    }
                    self?.cache[trackID] = ""
                    completion(nil)
                    return
                }
            }

            guard let data, !data.isEmpty else {
                self?.cache[trackID] = ""
                completion(nil)
                return
            }

            let canvasURL = ProtobufDecoder.decodeCanvasResponse(data: data)

            if let urlString = canvasURL {
                print("[Resona] ✅ Canvas found: \(urlString.prefix(80))...")
                self?.cache[trackID] = urlString
                completion(URL(string: urlString))
            } else {
                print("[Resona] No Canvas for track \(trackID)")
                self?.cache[trackID] = ""
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Helpers

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var chars = Array(hex)
        while chars.count >= 2 {
            let pair = String(chars.prefix(2))
            chars.removeFirst(2)
            if let byte = UInt8(pair, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }
}

// MARK: - Manual Protobuf Encoder

private enum ProtobufEncoder {
    static func encodeCanvasRequest(trackURI: String) -> Data {
        let trackMsg = encodeString(fieldNumber: 1, value: trackURI)
        var request = Data()
        request.append(encodeTag(fieldNumber: 1, wireType: 2))
        request.append(encodeVarint(trackMsg.count))
        request.append(trackMsg)
        return request
    }

    static func encodeString(fieldNumber: Int, value: String) -> Data {
        let bytes = Array(value.utf8)
        var data = Data()
        data.append(encodeTag(fieldNumber: fieldNumber, wireType: 2))
        data.append(encodeVarint(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    static func encodeTag(fieldNumber: Int, wireType: Int) -> Data {
        return encodeVarint((fieldNumber << 3) | wireType)
    }

    static func encodeVarint(_ value: Int) -> Data {
        var v = value
        var data = Data()
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
        return data
    }
}

// MARK: - Manual Protobuf Decoder

private enum ProtobufDecoder {
    static func decodeCanvasResponse(data: Data) -> String? {
        let bytes = [UInt8](data)
        var offset = 0

        while offset < bytes.count {
            guard let (fieldNumber, wireType, newOffset) = readTag(bytes: bytes, offset: offset) else { break }
            offset = newOffset

            if wireType == 2 {
                guard let (length, dataOffset) = readVarint(bytes: bytes, offset: offset) else { break }
                offset = dataOffset

                if fieldNumber == 1 {
                    let end = min(offset + length, bytes.count)
                    let subData = Array(bytes[offset..<end])
                    if let url = parseCanvasMessage(bytes: subData), !url.isEmpty {
                        return url
                    }
                }
                offset += length
            } else if wireType == 0 {
                guard let (_, newOff) = readVarint(bytes: bytes, offset: offset) else { break }
                offset = newOff
            } else if wireType == 5 {
                offset += 4
            } else if wireType == 1 {
                offset += 8
            } else {
                break
            }
        }
        return nil
    }

    private static func parseCanvasMessage(bytes: [UInt8]) -> String? {
        var offset = 0
        while offset < bytes.count {
            guard let (fieldNumber, wireType, newOffset) = readTag(bytes: bytes, offset: offset) else { break }
            offset = newOffset

            if wireType == 2 {
                guard let (length, dataOffset) = readVarint(bytes: bytes, offset: offset) else { break }
                offset = dataOffset
                let end = min(offset + length, bytes.count)

                if fieldNumber == 2 {
                    return String(bytes: bytes[offset..<end], encoding: .utf8)
                }
                offset = end
            } else if wireType == 0 {
                guard let (_, newOff) = readVarint(bytes: bytes, offset: offset) else { break }
                offset = newOff
            } else if wireType == 5 {
                offset += 4
            } else if wireType == 1 {
                offset += 8
            } else {
                break
            }
        }
        return nil
    }

    private static func readTag(bytes: [UInt8], offset: Int) -> (fieldNumber: Int, wireType: Int, newOffset: Int)? {
        guard let (value, newOffset) = readVarint(bytes: bytes, offset: offset) else { return nil }
        return (value >> 3, value & 0x07, newOffset)
    }

    private static func readVarint(bytes: [UInt8], offset: Int) -> (value: Int, newOffset: Int)? {
        var result = 0
        var shift = 0
        var i = offset
        while i < bytes.count {
            let byte = bytes[i]
            result |= Int(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 {
                return (result, i)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
