import SwiftUI

// MARK: - ServiceConflictView
//
// Shown as a sheet when both Spotify and Apple Music are playing at the same time.
// The user picks which source should drive the wallpaper.

struct ServiceConflictView: View {

    @ObservedObject var detectionService: MusicDetectionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {

            // Icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            // Title
            VStack(spacing: 6) {
                Text("Two services are playing")
                    .font(.headline)
                Text("Which should control your wallpaper right now?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Service cards
            HStack(spacing: 16) {
                ServiceCard(
                    source: .spotify,
                    track: detectionService.spotify.currentTrack
                ) {
                    detectionService.resolveConflict(preferring: .spotify)
                    dismiss()
                }

                ServiceCard(
                    source: .appleMusic,
                    track: detectionService.appleMusic.currentTrack
                ) {
                    detectionService.resolveConflict(preferring: .appleMusic)
                    dismiss()
                }
            }

            // "Always prefer" shortcut
            Divider()

            VStack(spacing: 8) {
                Text("Skip this prompt in the future:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Always use Spotify") {
                        AppSettings.shared.preferredService = .spotifyOnly
                        detectionService.resolveConflict(preferring: .spotify)
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Always use Apple Music") {
                        AppSettings.shared.preferredService = .appleMusicOnly
                        detectionService.resolveConflict(preferring: .appleMusic)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}

// MARK: - ServiceCard

private struct ServiceCard: View {
    let source: MusicSource
    let track: Track?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                // Service icon
                Image(systemName: source == .spotify
                      ? "dot.radiowaves.left.and.right"
                      : "applelogo")
                    .font(.system(size: 24))
                    .foregroundStyle(source == .spotify ? .green : .primary)

                Text(source.displayName)
                    .font(.system(size: 13, weight: .semibold))

                if let track = track {
                    VStack(spacing: 2) {
                        Text(track.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("No track info")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ServiceConflictView(detectionService: .shared)
}
