import SwiftUI

// MARK: - MenuBarView (Command Center)
//
// Compact glassmorphic popover — the primary interaction surface.
// Hero now-playing → quick controls → service strip → footer.

struct MenuBarView: View {

    @ObservedObject var detectionService: MusicDetectionService
    @ObservedObject private var spotify    = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared
    @ObservedObject private var settings   = AppSettings.shared

    @State private var spotifyConnecting = false
    @State private var appleMusicConnecting = false
    @State private var copiedLink = false

    var body: some View {
        VStack(spacing: 0) {
            nowPlaying
            thinDivider
            controls
            thinDivider
            services
            thinDivider
            footer
        }
        .frame(width: 300)
        .background(.ultraThinMaterial)
    }

    // MARK: - Now Playing

    private var nowPlaying: some View {
        Group {
            if let track = detectionService.activeTrack {
                HStack(spacing: 12) {
                    AsyncImage(url: track.artworkURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                                .overlay(Image(systemName: "music.note")
                                    .foregroundStyle(.tertiary))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(track.album)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer()
                            sourceBadge(track.source)
                        }
                    }
                }
                .padding(14)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resona").font(.system(size: 13, weight: .semibold))
                        Text("Play music to get started")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
    }

    // MARK: - Controls (The Dash)

    private var controls: some View {
        VStack(spacing: 8) {
            // Wave intensity
            HStack(spacing: 6) {
                Image(systemName: "water.waves")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Slider(value: $settings.waveIntensity, in: 0...1, step: 0.05)
                    .controlSize(.mini)
                Text(waveLabel)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }

            // Action pills
            HStack(spacing: 6) {
                pill("Canvas", icon: "play.rectangle.fill",
                     active: settings.showAnimatedWallpapers) {
                    settings.showAnimatedWallpapers.toggle()
                }

                if let track = detectionService.activeTrack,
                   track.source == .spotify {
                    pill(copiedLink ? "Copied" : "Link",
                         icon: copiedLink ? "checkmark" : "link",
                         active: copiedLink) {
                        let url = "https://open.spotify.com/track/\(track.id)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        withAnimation { copiedLink = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copiedLink = false }
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Services

    private var services: some View {
        HStack(spacing: 8) {
            connectionPill("Spotify", connected: spotify.isAuthenticated,
                           loading: spotifyConnecting,
                           connect: connectSpotify,
                           disconnect: { detectionService.spotify.disconnect() })

            connectionPill("Apple Music", connected: appleMusic.isAuthenticated,
                           loading: appleMusicConnecting,
                           connect: connectAppleMusic,
                           disconnect: { detectionService.appleMusic.disconnect() })
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gear")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Reusable bits

    private var thinDivider: some View {
        Divider().opacity(0.5)
    }

    private func sourceBadge(_ source: MusicSource) -> some View {
        let isSpotify = source == .spotify
        return HStack(spacing: 3) {
            Image(systemName: isSpotify ? "dot.radiowaves.left.and.right" : "applelogo")
                .font(.system(size: 8))
            Text(isSpotify ? "Spotify" : "AM")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(isSpotify ? .green : .primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background((isSpotify ? Color.green : Color.primary).opacity(0.1), in: Capsule())
    }

    private func pill(_ label: String, icon: String, active: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                active ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func connectionPill(_ label: String, connected: Bool,
                                loading: Bool,
                                connect: @escaping () -> Void,
                                disconnect: @escaping () -> Void) -> some View {
        Button(action: connected ? disconnect : connect) {
            HStack(spacing: 4) {
                if loading {
                    ProgressView().scaleEffect(0.5).frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                connected ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private var waveLabel: String {
        switch settings.waveIntensity {
        case 0:           return "Still"
        case 0.01...0.25: return "Gentle"
        case 0.26...0.50: return "Moderate"
        case 0.51...0.75: return "Lively"
        default:          return "Intense"
        }
    }

    // MARK: - Actions

    private func connectSpotify() {
        spotifyConnecting = true
        detectionService.spotify.connect { result in
            DispatchQueue.main.async {
                spotifyConnecting = false
                if case .failure(let e) = result {
                    Logger.error("Spotify connect failed: \(e)", category: .spotify)
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