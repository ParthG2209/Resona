import SwiftUI

// MARK: - MenuBarView (Command Center)

struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
            )
    }
}

extension View {
    func glassCard() -> some View {
        self.modifier(GlassCardModifier())
    }
}

struct MenuBarView: View {

    @ObservedObject var detectionService: MusicDetectionService
    @ObservedObject private var spotify    = SpotifyService.shared
    @ObservedObject private var appleMusic = AppleMusicService.shared
    @ObservedObject private var settings   = AppSettings.shared

    @State private var spotifyConnecting     = false
    @State private var appleMusicConnecting  = false
    @State private var copiedLink            = false
    @State private var showSpotifyLinkPrompt = false

    var body: some View {
        ZStack {
            AuraBackgroundView()
                .opacity(0.95)
                .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 10) {
                portalCard
                
                if showSpotifyLinkPrompt && !spotify.isAuthenticated {
                    linkSpotifyBanner
                }
                
                consoleCard
                footer
            }
            .padding(12)
        }
        .frame(width: 300, height: showSpotifyLinkPrompt && !spotify.isAuthenticated ? 460 : 400)
        .onReceive(NotificationCenter.default.publisher(for: .appleMusicNeedsSpotifyLink)) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showSpotifyLinkPrompt = true
            }
        }
    }

    // MARK: - Portal

    private var portalCard: some View {
        Group {
            if let track = detectionService.activeTrack {
                ZStack {
                    PortalBackdropView(isPlaying: detectionService.playbackState == .playing)
                        .allowsHitTesting(false)

                    AsyncImage(url: track.artworkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 24)
                                .opacity(0.28)
                                .scaleEffect(1.18)
                        }
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 12) {
                        HStack(alignment: .center, spacing: 14) {
                            AlbumPortalArt(url: track.artworkURL, isPlaying: detectionService.playbackState == .playing)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    sourceBadge(track.source)
                                    playbackBadge
                                }

                                Text(track.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.artist)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.76))
                                        .lineLimit(1)

                                    Text(track.album)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.48))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
                .frame(height: 172)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
            } else {
                ZStack {
                    PortalBackdropView(isPlaying: false)
                        .allowsHitTesting(false)

                    VStack(spacing: 12) {
                        Image("ResonaMenuBarIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .opacity(0.72)
                            .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 5)

                        VStack(spacing: 4) {
                            Text("Resona")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Waiting for music")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(height: 172)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
            }
        }
    }

    // MARK: - Console

    private var consoleCard: some View {
        VStack(spacing: 11) {
            HStack {
                Image(systemName: "water.waves")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                Text("Fluid Intensity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                Text(waveLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Slider(value: $settings.waveIntensity, in: 0...1, step: 0.05)
                .controlSize(.small)
                .tint(.white)

            HStack(spacing: 8) {
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

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)

            HStack(spacing: 8) {
                connectionPill("Spotify",
                               connected: spotify.isAuthenticated,
                               loading: spotifyConnecting,
                               connect: connectSpotify,
                               disconnect: { detectionService.spotify.disconnect() })

                connectionPill("Apple Music",
                               connected: appleMusic.isAuthenticated,
                               loading: appleMusicConnecting,
                               connect: connectAppleMusic,
                               disconnect: { detectionService.appleMusic.disconnect() })
                Spacer()
            }
        }
        .glassCard()
    }

    // MARK: - Spotify Link Banner
    
    private var linkSpotifyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.yellow)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Spotify Required")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("Link Spotify below to fetch high-res artwork & canvas videos for Apple Music.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            footerButton("Settings", icon: "gear") {
                openSettings()
            }

            Spacer()

            footerButton("Quit", icon: "power") {
                quitApplication()
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Reusable components

    private func sourceBadge(_ source: MusicSource) -> some View {
        let isSpotify = source == .spotify
        return HStack(spacing: 4) {
            Image(systemName: isSpotify ? "dot.radiowaves.left.and.right" : "applelogo")
                .font(.system(size: 9))
            Text(isSpotify ? "Spotify" : "AM")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(isSpotify ? Color.green : .white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(isSpotify ? 0.12 : 0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private var playbackBadge: some View {
        let isPlaying = detectionService.playbackState == .playing
        return HStack(spacing: 4) {
            Circle()
                .fill(isPlaying ? Color.green : Color.white.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(playbackLabel)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(isPlaying ? 0.82 : 0.55))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private var playbackLabel: String {
        switch detectionService.playbackState {
        case .playing: return "Live"
        case .paused:  return "Paused"
        case .stopped: return "Idle"
        }
    }

    private func pill(_ label: String, icon: String, active: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .magneticSpotlight(active: active)
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.65))
        }
        .buttonStyle(.plain)
    }

    private func connectionPill(_ label: String, connected: Bool,
                                loading: Bool,
                                connect: @escaping () -> Void,
                                disconnect: @escaping () -> Void) -> some View {
        Button(action: connected ? disconnect : connect) {
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 8, height: 8)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(connected ? Color.green : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Text(label).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(connected ? 0.9 : 0.65))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .magneticSpotlight(active: connected, baseOpacity: 0.08, activeOpacity: 0.18)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private func footerButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.showSettingsWindow()
        } else {
            NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
        }
        NotificationCenter.default.post(name: .closePopoverRequested, object: nil)
    }

    private func quitApplication() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.quitApplication()
        } else {
            NotificationCenter.default.post(name: .quitRequested, object: nil)
            NSApp.terminate(nil)
        }
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

// MARK: - Portal Visuals

private struct AlbumPortalArt: View {
    let url: URL?
    let isPlaying: Bool
    
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.42),
                            Color.white.opacity(0.10)
                        ],
                        center: .center
                    ),
                    lineWidth: 1.2
                )
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .blur(radius: 0.2)

            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
                    }
                }
            }
            .frame(width: 82, height: 82)
            .clipShape(Circle())
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 7)

            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
        }
        .frame(width: 92, height: 92)
        .onChange(of: isPlaying) { playing in
            if playing {
                withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            } else {
                withAnimation {
                    isSpinning = false
                }
            }
        }
        .onAppear {
            if isPlaying {
                withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
        }
    }
}

private struct PortalBackdropView: View {
    let isPlaying: Bool

    var body: some View {
        ZStack {
            // Static background gradient instead of TimelineView canvas
            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.46)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Soft static glows
            Circle()
                .fill(Color.white.opacity(isPlaying ? 0.08 : 0.04))
                .blur(radius: 40)
                .frame(width: 200, height: 200)
                .offset(x: -20, y: -40)
            
            Circle()
                .fill(Color.white.opacity(isPlaying ? 0.06 : 0.03))
                .blur(radius: 60)
                .frame(width: 250, height: 250)
                .offset(x: 40, y: 60)
        }
    }
}
