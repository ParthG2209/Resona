import AppKit
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

    static private(set) weak var shared: AppDelegate?

    private var menuBarManager: MenuBarManager!
    private var musicDetectionService: MusicDetectionService!
    private var settingsWindowController: NSWindowController?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Register resona:// URL scheme for OAuth callbacks
        URLSchemeHandler.shared.register()

        // Boot core services
        musicDetectionService = MusicDetectionService.shared
        menuBarManager = MenuBarManager(detectionService: musicDetectionService)
        setupAppActionObservers()

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

    private func setupAppActionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsWindow),
            name: .showSettingsRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quitApplication),
            name: .quitRequested,
            object: nil
        )
    }

    @objc func showSettingsWindow() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Resona Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            settingsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        settingsWindowController?.window?.orderFrontRegardless()
    }

    @objc func quitApplication() {
        NSApp.terminate(nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showDefaultWallpaperPicker = Notification.Name("showDefaultWallpaperPicker")
    static let showSettingsRequested      = Notification.Name("showSettingsRequested")
    static let closePopoverRequested      = Notification.Name("closePopoverRequested")
    static let trackDidChange             = Notification.Name("trackDidChange")
    static let playbackStateDidChange     = Notification.Name("playbackStateDidChange")
    static let serviceConflictDetected    = Notification.Name("serviceConflictDetected")
    static let quitRequested              = Notification.Name("quitRequested")
}
