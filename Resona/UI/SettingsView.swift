import SwiftUI
import UniformTypeIdentifiers

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var spotify = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared

    var body: some View {
        Form {
            Section("App") {
                Toggle("Enable Resona", isOn: $settings.isEnabled)
                Toggle("Launch at login", isOn: $settings.launchOnStartup)
                    .onChange(of: settings.launchOnStartup) {
                        // TODO: Register/unregister with SMAppService (macOS 13+)
                    }
            }

            Section("Music Service") {
                Picker("Active service", selection: $settings.preferredService) {
                    ForEach(ServicePreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Connections") {
                ServiceRow(
                    title: "Spotify",
                    isConnected: spotify.isAuthenticated,
                    onConnect: {
                        SpotifyService.shared.connect { _ in }
                    },
                    onDisconnect: {
                        SpotifyService.shared.disconnect()
                    }
                )
                ServiceRow(
                    title: "Apple Music",
                    isConnected: appleMusic.isAuthenticated,
                    onConnect: { Task { await AppleMusicService.shared.connect() } },
                    onDisconnect: { AppleMusicService.shared.disconnect() }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Appearance Tab

private struct AppearanceTab: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Wallpaper") {
                Toggle("Show animated wallpapers (Spotify Canvas)", isOn: $settings.showAnimatedWallpapers)
                    .help("Uses Spotify Canvas video when available. Requires Phase 3 implementation.")

                Picker("Transition style", selection: $settings.transitionStyle) {
                    ForEach(TransitionStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Picker("When music stops", selection: $settings.onMusicStop) {
                    ForEach(StopBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                HStack {
                    Text("Wave Intensity")
                    Spacer()
                    Slider(value: $settings.waveIntensity, in: 0...1, step: 0.05)
                        .frame(width: 160)
                    Text(waveLabel(settings.waveIntensity))
                        .frame(width: 60, alignment: .trailing)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .help("Controls how fast/strong the fluid background waves move")
            }

            Section("Default Wallpaper") {
                HStack {
                    if let url = AppSettings.shared.defaultWallpaperURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not set").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Browse…") { browseForWallpaper() }
                    Button("Use Current") { saveCurrentWallpaper() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func browseForWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.defaultWallpaperURL = url
        }
    }

    private func saveCurrentWallpaper() {
        if let url = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!) {
            AppSettings.shared.defaultWallpaperURL = url
        }
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

// MARK: - Advanced Tab

private struct AdvancedTab: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Cache") {
                Toggle("Clear cache on quit", isOn: $settings.clearCacheOnQuit)

                HStack {
                    Text("Max cache size")
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { Double(settings.maxCacheSizeMB) },
                            set: { settings.maxCacheSizeMB = Int($0) }
                        ),
                        in: 100...1000, step: 100
                    )
                    .frame(width: 140)
                    Text("\(settings.maxCacheSizeMB) MB")
                        .frame(width: 55, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Cache Now") { ArtworkCache.shared.clearAll() }
                    .foregroundStyle(.red)
            }

            Section("Polling") {
                HStack {
                    Text("Spotify poll interval")
                    Spacer()
                    Picker("", selection: $settings.pollingIntervalSeconds) {
                        ForEach([1, 2, 3, 5], id: \.self) { sec in
                            Text("\(sec)s").tag(sec)
                        }
                    }
                    .frame(width: 80)
                    .labelsHidden()
                }
            }

            Section("Debug") {
                Toggle("Enable debug logging", isOn: $settings.enableDebugLogging)
                Button("Open Log in Console") {
                    NSWorkspace.shared.open(URL(string: "console://")!)
                }
                .foregroundStyle(.secondary)
            }

            Section("Spotify Canvas (Animated Videos)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To enable animated video wallpapers, paste your Spotify sp_dc cookie below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        SecureField("sp_dc cookie", text: $settings.spotifySpDcCookie)
                            .textFieldStyle(.roundedBorder)

                        Button("?") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/Paxsenix0/Spotify-Canvas-API#3-set-required-environment-variable")!)
                        }
                        .help("How to get your sp_dc cookie")
                    }

                    Text("Open Spotify Web Player in your browser → DevTools (F12) → Application → Cookies → find sp_dc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Resona").font(.largeTitle.bold())
            Text("Version \(Constants.App.version)").foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                StatusInfoRow(label: "Spotify Canvas",        status: "Active (sp_dc required)", color: .green)
                StatusInfoRow(label: "Apple Music API",       status: "AppleScript",              color: .green)
                StatusInfoRow(label: "Animated Wallpapers",   status: "Active",                  color: .green)
            }
            .padding(.horizontal)

            Spacer()

            HStack(spacing: 20) {
                Link("Support", destination: URL(string: "mailto:\(Constants.App.supportEmail)")!)
                Link("Website", destination: URL(string: "https://resona.app")!)
            }
            .foregroundStyle(.tint)
        }
        .padding()
    }
}

// MARK: - Supporting Views

private struct ServiceRow: View {
    let title: String
    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 12))
                Button("Disconnect") { onDisconnect() }.foregroundStyle(.red)
            } else {
                Button("Connect") { onConnect() }
            }
        }
    }
}

private struct StatusInfoRow: View {
    let label: String
    let status: String
    let color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(status).foregroundStyle(color).font(.system(size: 12))
        }
    }
}