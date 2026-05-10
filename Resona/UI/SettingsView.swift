import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

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
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var settings   = AppSettings.shared
    @ObservedObject private var spotify    = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared

    var body: some View {
        Form {
            Section("App") {
                Toggle("Enable Resona", isOn: $settings.isEnabled)
                    .help("When disabled, the animated wallpaper is dismissed and reverted.")

                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchOnStartup },
                    set: { newValue in
                        settings.launchOnStartup = newValue
                        setLoginItem(enabled: newValue)
                    }
                ))
            }

            Section("Preferred Source") {
                Picker("Active service", selection: $settings.preferredService) {
                    ForEach(ServicePreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Connections") {
                connection(
                    title: "Spotify",
                    connected: spotify.isAuthenticated,
                    onConnect: { SpotifyService.shared.connect { _ in } },
                    onDisconnect: { SpotifyService.shared.disconnect() }
                )
                connection(
                    title: "Apple Music",
                    connected: appleMusic.isAuthenticated,
                    onConnect: { Task { await AppleMusicService.shared.connect() } },
                    onDisconnect: { AppleMusicService.shared.disconnect() }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func connection(title: String, connected: Bool,
                            onConnect: @escaping () -> Void,
                            onDisconnect: @escaping () -> Void) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(title)
            }
            Spacer()
            if connected {
                Text("Connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                Button("Disconnect", role: .destructive) { onDisconnect() }
                    .controlSize(.small)
            } else {
                Button("Connect") { onConnect() }
                    .controlSize(.small)
            }
        }
    }

    private func setLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)", category: .general)
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Wallpaper Engine") {
                Toggle("Enable Canvas videos", isOn: $settings.showAnimatedWallpapers)
                    .help("When available, displays the Spotify Canvas video loop. Toggling off mid-playback will switch to the static composed wallpaper.")

                Picker("When music stops", selection: $settings.onMusicStop) {
                    ForEach(StopBehavior.allCases, id: \.self) { b in
                        Text(b.displayName).tag(b)
                    }
                }
            }

            Section("Fluid Waves") {
                HStack {
                    Image(systemName: "water.waves")
                        .foregroundStyle(.secondary)
                    Text("Intensity")
                    Spacer()
                    Slider(value: $settings.waveIntensity, in: 0...1, step: 0.05)
                        .frame(width: 150)
                    Text(waveLabel(settings.waveIntensity))
                        .frame(width: 60, alignment: .trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default Wallpaper") {
                HStack {
                    if let url = settings.defaultWallpaperURL {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not set").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Browse…") { browseForWallpaper() }
                        .controlSize(.small)
                    Button("Use Current") { saveCurrentWallpaper() }
                        .controlSize(.small)
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
            settings.defaultWallpaperURL = url
        }
    }

    private func saveCurrentWallpaper() {
        if let screen = NSScreen.main,
           let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            settings.defaultWallpaperURL = url
        }
    }

    private func waveLabel(_ v: Double) -> String {
        switch v {
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

    var body: some View {
        Form {
            Section("Cache") {
                Toggle("Clear cache on quit", isOn: $settings.clearCacheOnQuit)

                HStack {
                    Text("Max size")
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button("Clear Cache Now", role: .destructive) {
                    ArtworkCache.shared.clearAll()
                }
                .controlSize(.small)
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
                .help("How often Resona checks Spotify's API. Lower = faster response, higher = less API load. Takes effect on next app launch or reconnect.")
            }

            Section("Spotify Canvas") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste your sp_dc cookie to enable Canvas video wallpapers.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        SecureField("sp_dc cookie", text: $settings.spotifySpDcCookie)
                            .textFieldStyle(.roundedBorder)

                        Button("?") {
                            NSWorkspace.shared.open(
                                URL(string: "https://github.com/Paxsenix0/Spotify-Canvas-API#3-set-required-environment-variable")!
                            )
                        }
                        .help("How to get your sp_dc cookie")
                    }

                    Text("Spotify Web Player → DevTools (F12) → Application → Cookies → sp_dc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Debug") {
                Toggle("Verbose logging", isOn: $settings.enableDebugLogging)
                Button("Open Console.app") {
                    NSWorkspace.shared.open(URL(string: "console://")!)
                }
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Resona").font(.title.bold())
            Text("Version \(Constants.App.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                statusRow("Spotify Canvas",     "Active (sp_dc)", .green)
                statusRow("Apple Music",        "Push Notification", .green)
                statusRow("Fluid Engine",       "Metal (30 fps)", .green)
            }

            Spacer()

            HStack(spacing: 20) {
                Link("Support", destination: URL(string: "mailto:\(Constants.App.supportEmail)")!)
                Link("Website", destination: URL(string: "https://resona.app")!)
            }
            .font(.system(size: 12))
            .foregroundStyle(.tint)

            Spacer().frame(height: 8)
        }
        .padding()
    }

    private func statusRow(_ label: String, _ status: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 260)
    }
}