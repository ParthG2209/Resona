import Foundation

// MARK: - Constants

enum Constants {

    // MARK: - Spotify

    enum Spotify {
        /// Register your app at https://developer.spotify.com/dashboard
        static let clientID     = "YOUR_SPOTIFY_CLIENT_ID"
        static let clientSecret = "YOUR_SPOTIFY_CLIENT_SECRET"  // ⚠️ Move to secure build config before shipping
        static let redirectURI  = "resona://callback/spotify"
        static let scopes       = "user-read-currently-playing user-read-playback-state"

        enum Endpoints {
            static let authBase       = "https://accounts.spotify.com"
            static let authorize      = "\(authBase)/authorize"
            static let token          = "\(authBase)/api/token"
            static let currentlyPlaying = "https://api.spotify.com/v1/me/player/currently-playing"
            static let playbackState  = "https://api.spotify.com/v1/me/player"
        }

        enum Keychain {
            static let accessToken  = "resona.spotify.accessToken"
            static let refreshToken = "resona.spotify.refreshToken"
            static let tokenExpiry  = "resona.spotify.tokenExpiry"
        }
    }

    // MARK: - Apple Music / MusicKit

    enum AppleMusic {
        /// Generate at https://developer.apple.com → Certificates, IDs & Profiles → Keys
        /// Store the .p8 file in your app bundle as MusicKitKey.p8
        static let teamID        = "YOUR_APPLE_TEAM_ID"
        static let keyID         = "YOUR_MUSICKIT_KEY_ID"
        static let developerTokenDuration: TimeInterval = 15_552_000  // 6 months in seconds

        enum Endpoints {
            static let base      = "https://api.music.apple.com/v1"
            static let catalog   = "\(base)/catalog"
        }

        enum Keychain {
            static let userToken = "resona.applemusic.userToken"
        }
    }

    // MARK: - Cache

    enum Cache {
        static let directoryName  = "artwork"
        static let spotifySubdir  = "spotify"
        static let appleMusicSubdir = "applemusic"
        static let expiryDays     = 7
        static let defaultMaxSizeMB = 500
    }

    // MARK: - Wallpaper

    enum Wallpaper {
        static let fadeTransitionDuration: TimeInterval = 2.0
        static let debounceInterval: TimeInterval       = 1.0   // wait 1s before applying new art
        static let preferredArtworkSize                 = 640   // pixels
    }

    // MARK: - App

    enum App {
        static let bundleIdentifier = "com.resona.app"
        static let name             = "Resona"
        static let version          = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        static let supportEmail     = "support@resona.app"  // update before launch
    }
}
