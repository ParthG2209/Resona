import SwiftUI

// MARK: - MenuBarView

struct MenuBarView: View {

    @ObservedObject var detectionService: MusicDetectionService
    @ObservedObject private var spotify = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared
    @State private var spotifyConnecting = false
    @State private var appleMusicConnecting = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            trackSection
            Divider()
            controlsSection
            Divider()
            statusSection
            Divider()
            footerSection
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text("Resona")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var trackSection: some View {
        Group {
            if let track = detectionService.activeTrack {
                HStack(spacing: 12) {
                    AsyncImage(url: track.artworkURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(track.album)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()

                    Image(systemName: track.source == .spotify ? "dot.radiowaves.left.and.right" : "applelogo")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.tertiary)
                    Text("Nothing playing")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 16) {
            ServiceToggle(
                label: "Spotify",
                icon: "dot.radiowaves.left.and.right",
                isConnected: spotify.isAuthenticated,
                isLoading: spotifyConnecting,
                onConnect: connectSpotify,
                onDisconnect: {
                    detectionService.spotify.disconnect()
                }
            )

            ServiceToggle(
                label: "Apple Music",
                icon: "applelogo",
                isConnected: appleMusic.isAuthenticated,
                isLoading: appleMusicConnecting,
                onConnect: connectAppleMusic,
                onDisconnect: {
                    detectionService.appleMusic.disconnect()
                }
            )

            Spacer()

            if let track = detectionService.activeTrack {
                Label(
                    track.isAnimatedArtworkAvailable ? "Animated" : "Static",
                    systemImage: track.isAnimatedArtworkAvailable ? "play.rectangle.fill" : "photo"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusSection: some View {
        HStack(spacing: 8) {
            StatusDot(label: "Spotify",     connected: spotify.isAuthenticated)
            Text("·").foregroundStyle(.tertiary)
            StatusDot(label: "Apple Music", connected: appleMusic.isAuthenticated)
            Spacer()
            if detectionService.activeTrack != nil {
                Text(AppSettings.shared.showAnimatedWallpapers ? "🎬 Animated" : "🖼 Static")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerSection: some View {
        HStack {
            SettingsLink {
                Text("Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Quit Resona") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Connect Actions

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

// MARK: - ServiceToggle

private struct ServiceToggle: View {
    let label: String
    let icon: String
    let isConnected: Bool
    let isLoading: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Button(action: isConnected ? onDisconnect : onConnect) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.system(size: 11))
                if !isLoading {
                    Image(systemName: isConnected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isConnected ? .green : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isConnected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - StatusDot

private struct StatusDot: View {
    let label: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}