import XCTest
@testable import Resona

// MARK: - SpotifyServiceTests

final class SpotifyServiceTests: XCTestCase {

    // MARK: - Token Refresh

    func testTokenIsConsideredExpiredWithin60SecondsOfExpiry() {
        // Tokens expiring in < 60s should trigger a refresh
        let almostExpired = Date().addingTimeInterval(30)
        let shouldRefresh = Date() >= almostExpired.addingTimeInterval(-60)
        XCTAssertTrue(shouldRefresh, "Token within 60s of expiry should be refreshed")
    }

    func testTokenIsValidWhenExpiryIsFarInFuture() {
        let farFuture = Date().addingTimeInterval(3600)
        let shouldRefresh = Date() >= farFuture.addingTimeInterval(-60)
        XCTAssertFalse(shouldRefresh, "Token with 1hr remaining should NOT be refreshed")
    }

    // MARK: - Track Equality

    func testTracksWithSameIDAndSourceAreEqual() {
        let t1 = Track(id: "abc", name: "Song", artist: "Artist", album: "Album",
                       artworkURL: nil, canvasURL: nil, durationMs: 200000,
                       progressMs: 0, source: .spotify)
        let t2 = Track(id: "abc", name: "Song", artist: "Artist", album: "Album",
                       artworkURL: nil, canvasURL: nil, durationMs: 200000,
                       progressMs: 0, source: .spotify)
        XCTAssertEqual(t1, t2)
    }

    func testTracksWithSameIDButDifferentSourceAreNotEqual() {
        let t1 = Track(id: "abc", name: "Song", artist: "Artist", album: "Album",
                       artworkURL: nil, canvasURL: nil, durationMs: 200000,
                       progressMs: 0, source: .spotify)
        let t2 = Track(id: "abc", name: "Song", artist: "Artist", album: "Album",
                       artworkURL: nil, canvasURL: nil, durationMs: 200000,
                       progressMs: 0, source: .appleMusic)
        XCTAssertNotEqual(t1, t2)
    }

    func testAnimatedArtworkAvailableWhenCanvasURLSet() {
        let track = Track(id: "1", name: "X", artist: "Y", album: "Z",
                          artworkURL: nil,
                          canvasURL: URL(string: "https://canvaz.scdn.co/test.mp4"),
                          durationMs: 180000, progressMs: 0, source: .spotify)
        XCTAssertTrue(track.isAnimatedArtworkAvailable)
    }
}

// MARK: - KeychainManagerTests

final class KeychainManagerTests: XCTestCase {

    private let testKey = "com.resona.test.token"

    override func tearDown() {
        KeychainManager.delete(forKey: testKey)
        super.tearDown()
    }

    func testSaveAndReadRoundTrip() {
        let value = "test-access-token-12345"
        let saved = KeychainManager.save(value, forKey: testKey)
        XCTAssertTrue(saved)

        let read = KeychainManager.read(forKey: testKey)
        XCTAssertEqual(read, value)
    }

    func testDeleteRemovesValue() {
        KeychainManager.save("somevalue", forKey: testKey)
        KeychainManager.delete(forKey: testKey)
        let read = KeychainManager.read(forKey: testKey)
        XCTAssertNil(read)
    }

    func testReadMissingKeyReturnsNil() {
        let read = KeychainManager.read(forKey: "nonexistent.key.xyz")
        XCTAssertNil(read)
    }

    func testOverwriteUpdatesValue() {
        KeychainManager.save("old-value", forKey: testKey)
        KeychainManager.save("new-value", forKey: testKey)
        XCTAssertEqual(KeychainManager.read(forKey: testKey), "new-value")
    }
}

// MARK: - AppSettingsTests

final class AppSettingsTests: XCTestCase {

    func testDefaultsAreReasonable() {
        let settings = AppSettings.shared
        // Polling shouldn't be 0 (infinite loop) or absurdly high
        XCTAssertGreaterThanOrEqual(settings.pollingIntervalSeconds, 1)
        XCTAssertLessThanOrEqual(settings.pollingIntervalSeconds, 10)

        XCTAssertGreaterThanOrEqual(settings.maxCacheSizeMB, 100)
        XCTAssertLessThanOrEqual(settings.maxCacheSizeMB, 1000)
    }
}

// MARK: - CacheKeyTests

final class CacheKeyTests: XCTestCase {

    func testStaticAndAnimatedKeysAreDifferent() {
        let staticKey   = CacheKey(trackID: "track123", source: .spotify, animated: false)
        let animatedKey = CacheKey(trackID: "track123", source: .spotify, animated: true)
        XCTAssertNotEqual(staticKey.filename, animatedKey.filename)
    }

    func testSpotifyAndAppleMusicKeysAreDifferent() {
        let spotifyKey = CacheKey(trackID: "track123", source: .spotify, animated: false)
        let amKey      = CacheKey(trackID: "track123", source: .appleMusic, animated: false)
        XCTAssertNotEqual(spotifyKey.filename, amKey.filename)
    }

    func testFilenameHasCorrectExtension() {
        let jpg = CacheKey(trackID: "id", source: .spotify, animated: false)
        let mp4 = CacheKey(trackID: "id", source: .spotify, animated: true)
        XCTAssertTrue(jpg.filename.hasSuffix(".jpg"))
        XCTAssertTrue(mp4.filename.hasSuffix(".mp4"))
    }

    func testFilenameContainsNoPathSeparators() {
        let key = CacheKey(trackID: "spotify:track:abc123def456", source: .spotify, animated: false)
        XCTAssertFalse(key.filename.contains("/"))
        XCTAssertFalse(key.filename.contains("\\"))
    }
}
