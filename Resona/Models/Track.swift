import Foundation

// MARK: - Track

/// Unified track model used across both Spotify and Apple Music.
struct Track: Equatable {

    let id: String
    let name: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let canvasURL: URL?      // Spotify Canvas (animated) – may be nil
    let durationMs: Int
    let progressMs: Int
    let source: MusicSource

    var isAnimatedArtworkAvailable: Bool {
        canvasURL != nil
    }

    // Two tracks are "the same" if their IDs match
    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }
}

// MARK: - MusicSource

enum MusicSource: String, Codable {
    case spotify
    case appleMusic

    var displayName: String {
        switch self {
        case .spotify:     return "Spotify"
        case .appleMusic:  return "Apple Music"
        }
    }
}

// MARK: - PlaybackState

enum PlaybackState: Equatable {
    case playing
    case paused
    case stopped
}
