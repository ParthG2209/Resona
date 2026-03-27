
import Foundation

// MARK: - Spotify API Response Models
// Isolated in their own file with no imports that could cause
// MainActor isolation. All structs are nonisolated and Sendable.

struct SpotifyTokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String
}

struct SpotifyCurrentlyPlayingResponse: Decodable, Sendable {
    let is_playing: Bool
    let progress_ms: Int?
    let item: SpotifyTrackItem?
}

struct SpotifyTrackItem: Decodable, Sendable {
    let id: String
    let name: String
    let duration_ms: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
}

struct SpotifyArtist: Decodable, Sendable {
    let name: String
}

struct SpotifyAlbum: Decodable, Sendable {
    let name: String
    let images: [SpotifyImage]
}

struct SpotifyImage: Decodable, Sendable {
    let url: String
    let width: Int?
    let height: Int?
}
