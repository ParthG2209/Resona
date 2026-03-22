import AppKit

// MARK: - URLSchemeHandler
//
// Spotify OAuth redirects back to resona://callback/spotify?code=...
// macOS routes that URL to our app via NSAppleEventManager.
//
// Register this in AppDelegate.applicationDidFinishLaunching:
//   URLSchemeHandler.shared.register()

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

        if path.contains("spotify") {
            SpotifyService.shared.handleCallback(url: url)
        } else {
            Logger.error("URLSchemeHandler: unknown callback path '\(path)'")
        }
    }
}
