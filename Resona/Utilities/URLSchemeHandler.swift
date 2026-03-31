import AppKit

// MARK: - URLSchemeHandler
//
// Spotify OAuth redirects back to resona://callback/spotify?code=...
// macOS routes that URL to our app via NSAppleEventManager.
//
// Routing priority:
//   1. SpotifySearchService.isHandlingSearchAuth == true
//      → Apple Music user is linking their Spotify account for artwork/Canvas lookups
//      → route to SpotifySearchService.handleCallback
//   2. Default
//      → route to SpotifyService.handleCallback (standard playback OAuth)

final class URLSchemeHandler: NSObject {

    static let shared = URLSchemeHandler()
    private override init() {}

    func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor,
                            replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else {
            Logger.error("URLSchemeHandler: could not parse incoming URL")
            return
        }

        Logger.info("URLSchemeHandler received: \(url.absoluteString)")

        switch url.host {
        case "callback":
            handleCallback(url: url)
        default:
            Logger.error("URLSchemeHandler: unrecognised host '\(url.host ?? "nil")'")
        }
    }

    // MARK: - Routing

    private func handleCallback(url: URL) {
        let path = url.path

        guard path.contains("spotify") else {
            Logger.error("URLSchemeHandler: unknown callback path '\(path)'")
            return
        }

        // If SpotifySearchService initiated an OAuth flow for an Apple Music user
        // linking their Spotify account, route the callback there first.
        if SpotifySearchService.shared.isHandlingSearchAuth {
            print("[Resona] URLSchemeHandler: routing callback → SpotifySearchService (Apple Music link)")
            SpotifySearchService.shared.handleCallback(url: url)
        } else {
            print("[Resona] URLSchemeHandler: routing callback → SpotifyService (playback auth)")
            SpotifyService.shared.handleCallback(url: url)
        }
    }
}