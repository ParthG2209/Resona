import SwiftUI

// MARK: - MenuBarView

struct MenuBarView: View {

    @ObservedObject var detectionService: MusicDetectionService
    @State private var showSettings = false

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
                    // Artwork thumbnail
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

                    // Source badge
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
            // Service toggles
            ServiceToggle(
                label: "Spotify",
                icon: "dot.radiowaves.left.and.right",
                isConnected: detectionService.spotify.isAuthenticated,
                onConnect: { detectionService.spotify.connect { _ in } },
                onDisconnect: { detectionService.spotify.disconnect() }
            )

            ServiceToggle(
                label: "Apple Music",
                icon: "applelogo",
                isConnected: detectionService.appleMusic.isAuthenticated,
                onConnect: { Task { await detectionService.appleMusic.connect() } },
                onDisconnect: { detectionService.appleMusic.disconnect() }
            )

            Spacer()

            // Animated indicator
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
            // Spotify status
            StatusDot(
                label: "Spotify",
                connected: detectionService.spotify.isAuthenticated
            )

            Text("·").foregroundStyle(.tertiary)

            // Apple Music status
            StatusDot(
                label: "Apple Music",
                connected: detectionService.appleMusic.isAuthenticated
            )

            Spacer()

            // Wallpaper type
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
            Button("Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))

            Spacer()

            Button("Quit Resona") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - ServiceToggle

private struct ServiceToggle: View {
    let label: String
    let icon: String
    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Button(action: isConnected ? onDisconnect : onConnect) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
                Image(systemName: isConnected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isConnected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1),
                        in: Capsule())
        }
        .buttonStyle(.plain)
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
