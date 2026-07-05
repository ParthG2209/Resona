<p align="center">
  <img src="Public/resona_logo.png" alt="Resona" width="160" height="160" style="border-radius: 32px;">
</p>

<h1 align="center">Resona</h1>

<p align="center">
  <strong>Your music, your wallpaper. Alive.</strong><br>
  <sub>A native macOS menu bar utility that transforms your desktop into a living canvas of album art — powered by Metal GPU shaders, real-time music detection, and Spotify Canvas videos.</sub>
</p>

<p align="center">
  <a href="https://resona-zeta.vercel.app"><img src="https://img.shields.io/badge/Website-resona-ff4d00?style=for-the-badge&logo=vercel&logoColor=white" alt="Website"></a>
  <a href="https://github.com/ParthG2209/Resona/releases"><img src="https://img.shields.io/github/v/release/ParthG2209/Resona?include_prereleases&style=for-the-badge&label=download&color=00e1ff" alt="Download"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013+-111111?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/swift-5.9+-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Metal-GPU%20Accelerated-8B5CF6?style=flat-square&logo=apple&logoColor=white" alt="Metal">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon-333333?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-22c55e?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/github/stars/ParthG2209/Resona?style=flat-square&color=f59e0b" alt="Stars">
</p>

---

> [!IMPORTANT]
> **Resona is currently in a closed beta.** Due to Spotify API limits for development applications, the beta is strictly limited to **25 members**. 
> 
> To request access, please email **[getresona@gmail.com](mailto:getresona@gmail.com)** so your account can be manually added to the developer dashboard.

---

## Overview

Resona detects what you are listening to — on **Spotify** or **Apple Music** — and renders an animated fluid wallpaper in real time, derived from the album artwork's dominant color palette. When a Spotify Canvas video is available, it plays the artist's official looping video directly on your desktop instead. When you stop playing music, it gracefully reverts back to your original wallpaper.

The entire application lives in your menu bar. No Dock icon. No main window. No interruptions.

---

## Table of Contents

- [Features](#features)
- [System Requirements](#system-requirements)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Technical Deep Dive](#technical-deep-dive)
- [Project Structure](#project-structure)
- [Privacy and Security](#privacy-and-security)
- [Known Limitations](#known-limitations)
- [Contributing](#contributing)
- [License](#license)

---

## Features

### Music Detection

| Capability | Spotify | Apple Music | Browser Tab (YouTube, etc.) |
|:--|:--|:--|:--|
| Track detection | OAuth 2.0 PKCE + Web API polling | `DistributedNotificationCenter` (zero-cost) | System now-playing via `mediaremote-adapter` |
| Playback state | Real-time via API | Notification payload | Now-playing stream |
| Album artwork | Spotify CDN (up to 640px) | **Music.app native, full-res (no Spotify required)** | Now-playing artwork |
| Canvas video | Unofficial protobuf API | Optional, via Spotify track match | — |
| Authentication | Browser-based OAuth flow | macOS Automation (Apple Events) | None — reads system now-playing |
| Rate limiting | 5-second polling interval | Event-driven, no polling | Event-driven, debounced |

**Apple Music no longer requires Spotify.** Artwork is read directly from Music.app via a single Apple Event per track change (the permission the app already declared). A linked Spotify account is now optional — it only adds Canvas videos.

**Browser tab audio** (YouTube and any HTML5 media session in Safari / Chrome / Brave / Edge / Arc / etc.) is detected through the system-wide Now Playing feed. Because macOS 15.4+ gates direct `MediaRemote` access behind a private entitlement, Resona reads it the way other native tools do — by spawning the vendored [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter) under the system `/usr/bin/perl`. See [Privacy and Security](#privacy-and-security).

Resona includes automatic conflict resolution. If both music services are playing simultaneously, a native dialog prompts you to select which source to follow. Browser tab audio is a deliberate foreground action, so it applies directly.

### Animated Wallpaper Engine

- **Metal Fragment Shader** — A real-time GPU-accelerated fluid simulation using simplex noise with double domain warping, rendered to a borderless `NSWindow` at desktop level.
- **Hybrid Color Extraction** — `CIAreaAverage` applied to a 3x3 spatial grid, combined with farthest-first traversal for distinct color selection. Produces vibrant, representative 5-color palettes from any album artwork.
- **Spotify Canvas** — When available, plays Spotify's official looping Canvas videos as your wallpaper using `AVQueuePlayer` with `AVPlayerLooper` for seamless loops.
- **Multi-Display** — Renders independently across all connected screens.
- **Thermal Management** — Renders at 30fps with half-resolution upscaling. The shader and video player automatically pause when music stops, driving GPU usage to zero during idle.

### Menu Bar Interface

- Glassmorphic dark UI with a spinning vinyl album art portal
- Real-time track info: name, artist, album, and source badge
- Fluid intensity slider with labeled presets (Still, Gentle, Moderate, Lively, Intense)
- One-click connect and disconnect for each music service
- Quick copy Spotify track link to clipboard
- Canvas toggle for enabling or disabling animated wallpapers
- Integrated Metal shader background in the popover itself

### Customization

| Setting | Default | Description |
|:--|:--|:--|
| Wave Intensity | 50% | Controls fluid animation speed. 0% = still, 100% = full motion |
| Animated Wallpapers | On | Toggle between animated Metal shader and static composed image mode |
| Transition Style | Fade | Fade (2 second crossfade) or instant wallpaper transitions |
| On Music Stop | Keep Last Art | Keep the last wallpaper or revert to your original desktop image |
| Cache Size | 500 MB | Maximum artwork cache size on disk |
| Clear Cache on Quit | Off | Auto-delete cached artwork when Resona closes |
| Polling Interval | 5 seconds | Spotify API polling frequency (minimum: 5 seconds) |

---

## System Requirements

| Requirement | Minimum |
|:--|:--|
| Operating System | macOS 13 Ventura |
| Processor | Apple Silicon (M1, M2, M3, M4) |
| GPU | Metal-compatible (all Apple Silicon) |
| Xcode | 15.0+ (for building from source) |
| Swift | 5.9+ |

---

## Installation

### Download (Recommended)

1. Visit [resona-zeta.vercel.app](https://resona-zeta.vercel.app) or the [Releases](https://github.com/ParthG2209/Resona/releases) page
2. Download `Resona.dmg`
3. Open the DMG and drag `Resona.app` into your Applications folder
4. Because the app is not signed/notarized, macOS Gatekeeper may flag it as "damaged". Open Terminal and run the following command to clear the quarantine attributes:
   ```bash
   xattr -cr /Applications/Resona.app
   ```
5. On first launch, right-click the app, click **Open**, then click **Open** in the confirmation dialog.

### Build from Source

```bash
git clone https://github.com/ParthG2209/Resona.git
cd Resona
open Resona.xcodeproj
```

In Xcode, select the **Resona** scheme, set the destination to **My Mac**, and press `Cmd + R`.

---

## Getting Started

1. **Launch** — Resona appears as an icon in your menu bar. It does not appear in the Dock.
2. **Connect Spotify** — Click the menu bar icon, then tap the Spotify pill. You will be redirected to your browser to authorize via OAuth. The callback URI (`resona://callback/spotify`) handles the token exchange automatically.
3. **Connect Apple Music** — Tap the Apple Music pill. macOS will prompt you to grant Automation permission for Music.app. Click Allow.
4. **Play music** — Start playing any track. Your desktop will transform within seconds.
5. **Set your fallback wallpaper** — On first launch, Resona prompts you to select the wallpaper it should revert to when music stops.

---

## Configuration

All settings are accessible from the **Settings** button in the menu bar dropdown, which opens a dedicated settings window with multiple tabs.

### Spotify Canvas Setup

Spotify Canvas requires an additional `sp_dc` cookie for authentication against Spotify's internal API. This is used exclusively for fetching Canvas video URLs.

1. Open Spotify Web Player in your browser and sign in
2. Open Developer Tools (`F12`) and navigate to Application > Cookies
3. Copy the value of the `sp_dc` cookie
4. Paste it into Resona's Settings under the Canvas tab

For detailed instructions, refer to the [Spotify Canvas API documentation](https://github.com/Paxsenix0/Spotify-Canvas-API#3-set-required-environment-variable).

---

## Architecture

```
                                 Resona Architecture
 ─────────────────────────────────────────────────────────────────────

    ┌────────────────┐              ┌────────────────────┐
    │   SpotifyService│              │  AppleMusicService  │
    │   (OAuth + API) │              │  (DistributedNotif)  │
    └───────┬────────┘              └─────────┬──────────┘
            │                                 │
            └──────────┐         ┌────────────┘
                       ▼         ▼
              ┌─────────────────────────┐
              │  MusicDetectionService   │
              │  (conflict resolution,   │
              │   state management)      │
              └───────────┬─────────────┘
                          │
                          ▼
              ┌─────────────────────────┐
              │    WallpaperManager      │
              │  (routing + transitions) │
              └─────┬───────────┬───────┘
                    │           │
          ┌─────────▼──┐   ┌───▼──────────────┐
          │  Animated   │   │   Static Mode     │
          │  Wallpaper  │   │  (CIFilter +      │
          │  Controller │   │   NSWorkspace)     │
          └──┬──────┬───┘   └───────────────────┘
             │      │
     ┌───────▼┐  ┌──▼──────────┐
     │ Metal   │  │ AVQueuePlayer│
     │ Shader  │  │ (Canvas)     │
     └────────┘  └─────────────┘
```

### Data Flow

1. **Detection** — `SpotifyService` polls the Web API every 5 seconds. `AppleMusicService` listens for `com.apple.Music.playerInfo` distributed notifications with zero CPU overhead.
2. **Coordination** — `MusicDetectionService` unifies both sources. If both are active, it presents `ServiceConflictView` for the user to choose.
3. **Artwork Processing** — The active track's artwork is fetched, cached via `ArtworkCache`, and passed through `CIAreaAverage` on a 3x3 grid for color extraction.
4. **Rendering** — In animated mode, extracted colors are uploaded as uniforms to the Metal fragment shader. In static mode, a composed image is generated using `CIFilter` and set via `NSWorkspace.shared.setDesktopImageURL`.
5. **Canvas** — If the track has a Canvas video, `SpotifyCanvasService` fetches the video URL and `AVQueuePlayer` replaces the shader output.
6. **Lifecycle** — When playback stops, the shader and video player pause immediately (zero GPU draw). The wallpaper either persists or reverts based on user settings.

---

## Technical Deep Dive

### The Metal Shader

The fluid wallpaper is powered by a real-time Metal fragment shader. The rendering pipeline consists of:

| Stage | Description |
|:--|:--|
| Simplex Noise | Generates organic, flowing noise patterns across UV space |
| Double Domain Warping | Applies two layers of domain distortion to create fluid-like motion |
| 5-Color Palette Blending | Smoothly interpolates between extracted album colors using the noise output |
| Radial Vignette | Darkens edges for depth and visual grounding |
| Half-Resolution Upscaling | Renders at 50% internal resolution and lets the GPU hardware upscale, reducing thermal output by approximately 60% |

Frame rate is capped at **30fps**. The shader is compiled at launch and runs entirely on the GPU with no CPU-side per-frame work.

### Color Extraction Pipeline

```
Album Artwork (640x640)
        │
        ▼
  ┌─────────────┐
  │  3x3 Grid    │    9 spatial regions
  │  Subdivision  │
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │ CIAreaAverage │    Per-region dominant color
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Farthest-   │    Selects 5 maximally
  │  First       │    distinct colors
  │  Traversal   │
  └──────┬──────┘
         │
         ▼
   5-Color Palette → Metal Shader Uniforms
```

### Spotify Integration

| Component | Implementation |
|:--|:--|
| Authentication | OAuth 2.0 with PKCE. Authorization code exchanged for access and refresh tokens. Tokens stored in macOS Keychain. |
| Token Refresh | Automatic refresh on 401 response. Refresh token persisted across sessions. |
| Playback Polling | `Timer`-based polling at a configurable interval (minimum 5 seconds). Fetches `/v1/me/player/currently-playing`. |
| Artwork Search | `SpotifySearchService` performs multi-strategy fuzzy matching (exact, relaxed, title-only) with artist validation. |
| Canvas Fetch | `SpotifyCanvasService` authenticates via `sp_dc` cookie, generates a TOTP token, and queries the protobuf Canvas endpoint. |
| URL Scheme | `resona://callback/spotify` registered in `Info.plist` for OAuth redirect. Handled by `URLSchemeHandler`. |

### Apple Music Integration

| Component | Implementation |
|:--|:--|
| Track Detection | `DistributedNotificationCenter` observes `com.apple.Music.playerInfo`. Zero CPU cost — the OS pushes notifications to Resona. |
| Metadata | Extracted from the notification's `userInfo` dictionary: track name, artist, album, playback state, and duration. |
| Artwork & Canvas | `SpotifySearchService` looks up the Apple Music track on Spotify to fetch high-res artwork and Canvas video URLs. |
| Permissions | Requires one-time macOS Automation permission grant for Music.app (triggered by `NSAppleEventsUsageDescription` in Info.plist), plus optional Spotify OAuth for enhanced artwork/Canvas support. |

### Power and Thermal Management

Resona is designed to be thermally invisible during normal use:

| Optimization | Impact |
|:--|:--|
| 30fps shader cap | 50% fewer GPU frames vs 60fps |
| Half-resolution rendering | ~60% reduction in fragment shader invocations |
| 5-second polling interval | 80% fewer network requests vs 1-second polling |
| Shader auto-pause on music stop | Zero GPU draw when idle |
| Canvas auto-pause on music stop | Zero video decoding when idle |
| Popover shader lifecycle | Metal view pauses when menu bar popover closes |
| Event-driven Apple Music | No polling, no timers, no CPU wake-ups |
| Static `PortalBackdropView` | Replaced `TimelineView` canvas with static gradients |

---

## Project Structure

```
Resona/
├── App/
│   ├── ResonaApp.swift                  # @main entry point and AppDelegate
│   └── MenuBarManager.swift             # NSStatusItem, popover, and icon management
│
├── Models/
│   ├── Track.swift                      # Unified track model (Spotify + Apple Music)
│   ├── AppSettings.swift                # @UserDefault-backed persistent preferences
│   ├── Artwork.swift                    # Artwork metadata container
│   └── SpotifyModels.swift              # Codable types for Spotify API responses
│
├── Services/
│   ├── MusicDetectionService.swift      # Central coordinator and conflict resolver
│   ├── SpotifyService.swift             # OAuth 2.0 PKCE + Web API client
│   ├── SpotifySearchService.swift       # Multi-strategy track search with artist matching
│   ├── SpotifyCanvasService.swift       # Canvas video URL fetcher (protobuf + TOTP)
│   ├── AppleMusicService.swift          # DistributedNotification + AppleScript bridge
│   ├── WallpaperManager.swift           # Routes to animated or static wallpaper mode
│   ├── AnimatedWallpaperController.swift # Metal shader engine + color extraction + lifecycle
│   └── PopoverFluidBackground.swift     # Shared Metal background for the menu bar popover
│
├── UI/
│   ├── MenuBarView.swift                # Menu bar dropdown (glassmorphic SwiftUI)
│   ├── SettingsView.swift               # Multi-tab settings window
│   ├── ServiceConflictView.swift        # Dual-source conflict resolution dialog
│   ├── DefaultWallpaperPickerView.swift # First-launch wallpaper selection
│   ├── FluidPopoverViewController.swift # NSViewController hosting the Metal popover shader
│   ├── AuraBackgroundView.swift         # Ambient background layer for the menu bar
│   ├── MagneticSpotlightModifier.swift  # Cursor-tracking spotlight effect
│   └── WaveSplineSlider.swift           # Custom fluid intensity slider
│
├── Cache/
│   └── ArtworkCache.swift               # Size-limited disk cache for artwork
│
├── Utilities/
│   ├── Constants.swift                  # API keys, endpoints, and configuration values
│   ├── KeychainManager.swift            # macOS Keychain wrapper for credential storage
│   ├── Logger.swift                     # Categorized logging (spotify, apple, wallpaper, cache)
│   └── URLSchemeHandler.swift           # resona:// URL scheme handler for OAuth callbacks
│
├── Assets.xcassets/                     # App icons (16px through 1024px)
└── Info.plist                           # Bundle config, URL schemes, LSUIElement, permissions

site/                                    # React + Vite landing page
├── src/
│   ├── engine/FluidEngine.js            # WebGL port of the Metal shader for the website
│   ├── ui/                              # Page sections (Hero, Gallery, Hardware, etc.)
│   └── config/download.js               # Central download URL configuration
└── public/
    └── resona_logo.png
```

---

## Privacy and Security

- **No data collection.** Resona does not collect, store, or transmit any user data, listening history, or analytics.
- **Local-only processing.** All artwork processing, color extraction, and shader rendering happens on-device.
- **Keychain storage.** OAuth tokens and the `sp_dc` cookie are stored exclusively in the macOS Keychain, never in plain text.
- **No network requests beyond APIs.** Resona communicates only with the Spotify Web API (`api.spotify.com`), Spotify's token endpoint, and the Canvas protobuf endpoint. There is no telemetry, no analytics server, and no third-party SDKs.
- **Bundled helper process (browser tab audio only).** When you enable browser tab detection, Resona spawns the vendored [`mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause) under the system `/usr/bin/perl` to read macOS's system-wide Now Playing feed — the only practical way to access it from an app bundle on macOS 15.4+. This reads the currently-playing track's title, artist, and artwork for **browser** sessions only; it runs entirely on-device, sends nothing off the machine, and is inert unless you turn the feature on. The vendored adapter carries its own license under `Vendor/mediaremote-adapter/`.
- **Apple Music artwork stays on-device.** Cover art is read straight from Music.app via a local Apple Event — no third-party service, no network round-trip.
- **Open source.** The complete source code is available for inspection.

---

## Known Limitations

| Limitation | Context |
|:--|:--|
| Spotify alpha limited to 25 users | Spotify restricts Development Mode apps to 25 manually whitelisted users. A quota extension requires a registered business entity with 250k+ MAU. |
| Canvas relies on unofficial APIs | Spotify Canvas is not part of the public Web API. The protobuf endpoint may change without notice. |
| Apple Music requires Music.app | Track detection relies on distributed notifications from the native macOS Music.app; artwork is read locally from Music.app via an Apple Event. |
| Browser tab audio needs the bundled helper | YouTube/browser detection spawns the vendored `mediaremote-adapter` under the system `/usr/bin/perl` (present by default on macOS). Direct `MediaRemote` access is gated behind a private entitlement on macOS 15.4+, so an app bundle cannot read it without this helper. |
| Not Mac App Store compatible | macOS Automation for Music.app, desktop-level window management, and the now-playing helper require capabilities incompatible with the Mac App Store sandbox. |
| Not notarized | Requires right-click > Open on first launch. An Apple Developer Program membership ($99/year) is needed for notarization. |

---

## Contributing

Contributions are welcome. Please open an issue first to discuss what you would like to change.

1. Fork the repository
2. Create your feature branch: `git checkout -b feature/your-feature`
3. Commit your changes: `git commit -m "feat: add your feature"`
4. Push to the branch: `git push origin feature/your-feature`
5. Open a Pull Request

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Designed and built by <a href="https://github.com/ParthG2209">Parth Gupta</a></sub>
</p>
