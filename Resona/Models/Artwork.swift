import Foundation
import AppKit

// MARK: - ArtworkType

enum ArtworkType {
    case animated(URL)   // local MP4/GIF path
    case still(URL)      // local image path (PNG/JPEG)
    case none
}

// MARK: - Artwork

struct Artwork {
    let type: ArtworkType
    let sourceTrack: Track

    var isAnimated: Bool {
        if case .animated = type { return true }
        return false
    }

    var localURL: URL? {
        switch type {
        case .animated(let url): return url
        case .still(let url):    return url
        case .none:              return nil
        }
    }
}
