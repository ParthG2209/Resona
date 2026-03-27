import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - DefaultWallpaperPickerView
//
// Presented as a panel on first launch so the user can choose the wallpaper
// Resona should restore when no music is playing.

struct DefaultWallpaperPickerView: View {

    @State private var selectedURL: URL? = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Set Your Default Wallpaper")
                    .font(.headline)
                Text("Resona will restore this wallpaper when no music is playing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Preview
            Group {
                if let url = selectedURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 280, height: 158)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.separator, lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .frame(width: 280, height: 158)
                        .overlay(
                            Text("No preview")
                                .foregroundStyle(.tertiary)
                        )
                }
            }

            // Selected filename
            if let url = selectedURL {
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Actions
            HStack(spacing: 12) {
                Button("Browse…") { browseForFile() }
                    .buttonStyle(.bordered)

                Button("Use Current Desktop") { useCurrentDesktop() }
                    .buttonStyle(.bordered)
            }

            Divider()

            HStack {
                Button("Skip for now") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Confirm") {
                    AppSettings.shared.defaultWallpaperURL = selectedURL
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURL == nil)
            }
        }
        .padding(28)
        .frame(width: 360)
    }

    // MARK: - Helpers

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your default wallpaper"
        if panel.runModal() == .OK {
            selectedURL = panel.url
        }
    }

    private func useCurrentDesktop() {
        selectedURL = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
    }
}

#Preview {
    DefaultWallpaperPickerView()
}
