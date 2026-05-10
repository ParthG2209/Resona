import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "sparkles") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 560, height: 500)
        .background(SettingsBackground())
        .preferredColorScheme(.dark)
    }
}

private struct SettingsBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.055, green: 0.050, blue: 0.052),
                Color(red: 0.030, green: 0.038, blue: 0.040),
                Color.black.opacity(0.96)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var spotify = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared
    @ObservedObject private var detectionService = MusicDetectionService.shared

    @State private var spotifyConnecting = false
    @State private var appleMusicConnecting = false
    @State private var loginMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            SettingsSectionCard("App") {
                Toggle("Enable Resona", isOn: $settings.isEnabled)

                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchOnStartup },
                    set: { setLoginItem(enabled: $0) }
                ))

                if !loginMessage.isEmpty {
                    Text(loginMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear(perform: syncLoginItemStatus)

            SettingsSectionCard("Preferred Source") {
                Picker("Active service", selection: $settings.preferredService) {
                    ForEach(ServicePreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            }

            SettingsSectionCard("Connections") {
                ConnectionRow(
                    title: "Spotify",
                    connected: spotify.isAuthenticated,
                    loading: spotifyConnecting,
                    connect: connectSpotify,
                    disconnect: { detectionService.spotify.disconnect() }
                )

                Divider().opacity(0.35)

                ConnectionRow(
                    title: "Apple Music",
                    connected: appleMusic.isAuthenticated,
                    loading: appleMusicConnecting,
                    connect: connectAppleMusic,
                    disconnect: { detectionService.appleMusic.disconnect() }
                )
            }

            Spacer()
        }
        .settingsTabPadding()
    }

    private func syncLoginItemStatus() {
        guard #available(macOS 13.0, *) else { return }
        settings.launchOnStartup = SMAppService.mainApp.status == .enabled
    }

    private func setLoginItem(enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            settings.launchOnStartup = false
            loginMessage = "Launch at login requires macOS 13 or later."
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchOnStartup = enabled
            loginMessage = enabled ? "Resona will launch with macOS." : "Launch at login disabled."
        } catch {
            settings.launchOnStartup = SMAppService.mainApp.status == .enabled
            loginMessage = "macOS rejected the login item change."
            Logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)", category: .general)
        }
    }

    private func connectSpotify() {
        spotifyConnecting = true
        detectionService.spotify.connect { result in
            DispatchQueue.main.async {
                spotifyConnecting = false
                if case .failure(let error) = result {
                    Logger.error("Spotify connect failed: \(error)", category: .spotify)
                }
            }
        }
    }

    private func connectAppleMusic() {
        appleMusicConnecting = true
        Task {
            await detectionService.appleMusic.connect()
            appleMusicConnecting = false
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var wallpaperMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            SettingsSectionCard("Wallpaper") {
                Toggle("Enable Canvas videos", isOn: $settings.showAnimatedWallpapers)

                Picker("When music stops", selection: $settings.onMusicStop) {
                    ForEach(StopBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }

            SettingsSectionCard("Fluid Waves") {
                HStack {
                    Text("Intensity")
                    Slider(value: $settings.waveIntensity, in: 0...1, step: 0.05)
                    Text(waveLabel(settings.waveIntensity))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }

            SettingsSectionCard("Default Wallpaper") {
                HStack {
                    Text(settings.defaultWallpaperURL?.lastPathComponent ?? "Not set")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.defaultWallpaperURL == nil ? .tertiary : .secondary)
                        .lineLimit(1)

                    Spacer()

                    Button("Browse") { browseForWallpaper() }
                    Button("Use Current") { saveCurrentWallpaper() }
                    Button("Apply") { applyDefaultWallpaper() }
                        .disabled(settings.defaultWallpaperURL == nil)
                }

                if !wallpaperMessage.isEmpty {
                    Text(wallpaperMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .settingsTabPadding()
    }

    private func browseForWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultWallpaperURL = url
            wallpaperMessage = "Fallback set to \(url.lastPathComponent)."
        }
    }

    private func saveCurrentWallpaper() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            wallpaperMessage = "Could not read the current wallpaper."
            return
        }
        settings.defaultWallpaperURL = url
        wallpaperMessage = "Captured the current desktop wallpaper."
    }

    private func applyDefaultWallpaper() {
        WallpaperManager.shared.revertToUserWallpaper()
        wallpaperMessage = "Fallback wallpaper applied."
    }

    private func waveLabel(_ value: Double) -> String {
        switch value {
        case 0:           return "Still"
        case 0.01...0.25: return "Gentle"
        case 0.26...0.50: return "Moderate"
        case 0.51...0.75: return "Lively"
        default:          return "Intense"
        }
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var spotify = SpotifyService.shared
    @State private var cacheMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            SettingsSectionCard("Cache") {
                Toggle("Clear cache on quit", isOn: $settings.clearCacheOnQuit)

                HStack {
                    Text("Max size")
                    Slider(
                        value: Binding(
                            get: { Double(settings.maxCacheSizeMB) },
                            set: { newValue in
                                settings.maxCacheSizeMB = Int(newValue)
                                ArtworkCache.shared.enforceCurrentLimit()
                            }
                        ),
                        in: 100...1000,
                        step: 100
                    )
                    Text("\(settings.maxCacheSizeMB) MB")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }

                HStack {
                    Button("Clear Cache Now", role: .destructive) {
                        ArtworkCache.shared.clearAll()
                        cacheMessage = "Cache cleared."
                    }
                    Spacer()
                    Text(cacheMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSectionCard("Spotify") {
                HStack {
                    Text("Poll interval")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.pollingIntervalSeconds },
                        set: { newValue in
                            settings.pollingIntervalSeconds = newValue
                            if spotify.isAuthenticated {
                                SpotifyService.shared.startPolling()
                            }
                        }
                    )) {
                        ForEach([1, 2, 3, 5], id: \.self) { seconds in
                            Text("\(seconds)s").tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                }

                SecureField("sp_dc cookie for Canvas", text: $settings.spotifySpDcCookie)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsSectionCard("Debug") {
                Toggle("Verbose logging", isOn: $settings.enableDebugLogging)

                HStack {
                    Button("Open Console") { openConsole() }
                    Spacer()
                }
            }

            Spacer()
        }
        .settingsTabPadding()
    }

    private func openConsole() {
        let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.open(appURL)
        } else if let url = URL(string: "console://") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var spotify = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image("ResonaMenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)

            Text("Resona")
                .font(.title2.bold())

            Text("Version \(Constants.App.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SettingsSectionCard("Status") {
                StatusLine("Engine", settings.isEnabled ? "Enabled" : "Disabled")
                StatusLine("Spotify", spotify.isAuthenticated ? "Connected" : "Disconnected")
                StatusLine("Apple Music", appleMusic.isAuthenticated ? "Connected" : "Disconnected")
            }
            .frame(width: 300)

            Link("Support", destination: URL(string: "mailto:\(Constants.App.supportEmail)")!)
                .font(.system(size: 12, weight: .medium))

            Spacer()
        }
        .settingsTabPadding()
    }
}

// MARK: - Components

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        )
    }
}

private struct ConnectionRow: View {
    let title: String
    let connected: Bool
    let loading: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(title)
            Spacer()
            if loading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 18)
            }
            Text(connected ? "Connected" : "Disconnected")
                .font(.system(size: 11))
                .foregroundStyle(connected ? .green : .secondary)
            if connected {
                Button("Disconnect", role: .destructive) {
                    disconnect()
                }
                .disabled(loading)
                .controlSize(.small)
            } else {
                Button("Connect") {
                    connect()
                }
                .disabled(loading)
                .controlSize(.small)
            }
        }
    }
}

private struct StatusLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 12))
    }
}

private extension View {
    func settingsTabPadding() -> some View {
        self
            .padding(.top, 10)
            .padding(.horizontal, 6)
    }
}
