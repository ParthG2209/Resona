import SwiftUI

@main
struct ResonaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — this is a menu bar only app.
        // Settings window is opened programmatically.
        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarManager: MenuBarManager!
    private var musicDetectionService: MusicDetectionService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Register resona:// URL scheme for OAuth callbacks
        URLSchemeHandler.shared.register()

        // Boot core services
        musicDetectionService = MusicDetectionService.shared
        menuBarManager = MenuBarManager(detectionService: musicDetectionService)

        // Start monitoring music
        musicDetectionService.startMonitoring()

        // Prompt for default wallpaper on first launch
        if AppSettings.shared.defaultWallpaperURL == nil {
            showDefaultWallpaperPicker()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        musicDetectionService.stopMonitoring()

        if AppSettings.shared.clearCacheOnQuit {
            ArtworkCache.shared.clearAll()
        }
    }

    private func showDefaultWallpaperPicker() {
        // Slight delay so menu bar is ready first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: .showDefaultWallpaperPicker, object: nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showDefaultWallpaperPicker = Notification.Name("showDefaultWallpaperPicker")
    static let trackDidChange             = Notification.Name("trackDidChange")
    static let playbackStateDidChange     = Notification.Name("playbackStateDidChange")
    static let serviceConflictDetected    = Notification.Name("serviceConflictDetected")
}
