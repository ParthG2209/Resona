import Foundation
import AppKit

// MARK: - MusicArtworkProvider
//
// Fetches the current Music.app track's identity AND album artwork in a single
// atomic Apple Event — NO Spotify dependency. Fired only on track change.
//
// Reading identity and artwork together is deliberate: Music.app's "current
// track" can advance between the playerInfo notification firing and this fetch
// (rapid skips, IPC latency). If we grabbed only the artwork, it could belong to
// a *different* song than the name/artist we're displaying → wrong cover art.
// Returning the name/artist from the same snapshot lets the caller detect and
// drop a stale update.
//
// This is what the app's own Info.plist NSAppleEventsUsageDescription was always
// for ("read album artwork from Music.app"). Music.app embeds full-resolution
// cover art (typically 600×600 JPEG).

enum MusicArtworkProvider {

    struct Snapshot {
        let name: String
        let artist: String
        let artwork: Data?
    }

    private static let script: NSAppleScript? = {
        // Returns {name, artist, raw artwork data} as an AppleScript list, or
        // `missing value` when stopped. Artwork is wrapped in its own try so a
        // track with no embedded art still yields name/artist.
        let source = """
        tell application "Music"
            if player state is stopped then return missing value
            set t to current track
            set n to name of t
            set a to artist of t
            try
                set d to raw data of artwork 1 of t
            on error
                set d to missing value
            end try
            return {n, a, d}
        end tell
        """
        return NSAppleScript(source: source)
    }()

    /// Returns the current Music.app track's identity + artwork bytes, or nil if
    /// Music is stopped or automation is denied. Runs a synchronous Apple Event,
    /// so call it off the main thread.
    static func currentSnapshot() -> Snapshot? {
        guard let script else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            Logger.error("MusicArtworkProvider: Apple Event failed — \(err)", category: .appleMusic)
            return nil
        }
        // `missing value` (stopped) comes back as a null descriptor, not a list.
        guard result.descriptorType != typeNull, result.numberOfItems >= 2 else { return nil }

        let name   = result.atIndex(1)?.stringValue ?? ""
        let artist = result.atIndex(2)?.stringValue ?? ""

        var artwork: Data?
        if let third = result.atIndex(3), third.descriptorType != typeNull {
            let d = third.data
            if d.count > 0 { artwork = d }
        }
        guard !name.isEmpty else { return nil }
        return Snapshot(name: name, artist: artist, artwork: artwork)
    }
}
