<p align="center">
  <img src="Public/banner.png" alt="Resona — Animated Album Art Wallpapers for macOS" width="100%">
</p>

<h1 align="center">Resona</h1>

<p align="center">
  <b>Your music, your wallpaper. Alive.</b><br>
  <sub>A macOS menu bar app that transforms your desktop into a living, breathing canvas of album art — powered by Metal shaders and real-time music detection.</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-5.9+-orange?style=flat-square&logo=swift" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/Metal-GPU%20Accelerated-purple?style=flat-square" alt="Metal">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
</p>

---

## What is Resona?

Resona detects what you're listening to — on **Spotify** or **Apple Music** — and transforms your entire desktop into an animated fluid wallpaper derived from the album artwork's color palette. Think Apple Music's "Now Playing" visualizer, but as your actual wallpaper.

When you stop playing music, it gracefully reverts back to your original wallpaper.

---

## ✨ Features

### 🎵 Music Detection
- **Spotify** — OAuth-based integration via the Spotify Web API. Real-time polling detects track changes, playplay state, and artwork.
- **Apple Music** — Zero-cost integration using `DistributedNotificationCenter` + AppleScript. No $99 developer membership required.
- **Conflict Resolution** — If both services are playing simultaneously, Resona prompts you to pick one.

### 🎨 Animated Wallpaper Engine
- **Metal Shader Rendering** — GPU-accelerated simplex noise fluid simulation with double domain warping, rendered directly to a desktop-level window.
- **Hybrid Color Extraction** — `CIAreaAverage` on a 3×3 spatial grid + farthest-first distinct color selection = accurate, vibrant palettes for every album.
- **Spotify Canvas Support** — When available, plays Spotify's official looping Canvas videos as your wallpaper instead.
- **Multi-display** — Works across all connected screens simultaneously.
- **Smooth Transitions** — 2-second fade between wallpapers; no jarring cuts.

### 🎛 Customization
- **Wave Intensity Slider** — Control how much the fluid moves, from subtle shimmer to full-speed waves.
- **Static Mode** — Prefer a still image? Resona composites the album art over a blurred, vignetted background.
- **Stop Behavior** — Choose to keep the last album art or revert to your original wallpaper.
- **Cache Management** — Configurable cache size with optional auto-clear on quit.

### 🖥 Menu Bar App
- Lives in your menu bar — no Dock icon, no main window.
- Shows current track, artist, album, and source at a glance.
- One-click connect/disconnect for each music service.

---

## 📸 How It Works

```
┌─────────────────────────────────────────────────────────┐
│                    Music Detection                       │
│  ┌──────────────┐            ┌───────────────────┐      │
│  │   Spotify     │            │   Apple Music      │      │
│  │  (OAuth API)  │            │  (AppleScript +    │      │
│  │  1s polling   │            │   Notifications)   │      │
│  └──────┬───────┘            └────────┬──────────┘      │
│         └──────────┬─────────────────┘                   │
│                    ▼                                      │
│          MusicDetectionService                           │
│          (conflict resolution)                           │
│                    │                                      │
│                    ▼                                      │
│           WallpaperManager                               │
│          ┌────────┴────────┐                             │
│          ▼                 ▼                              │
│    Animated Mode      Static Mode                        │
│   (Metal shader)    (CIFilter compose)                   │
│          │                 │                              │
│          ▼                 ▼                              │
│   AnimatedWallpaper   NSWorkspace                        │
│    Controller        .setDesktopImage                    │
└─────────────────────────────────────────────────────────┘
```

---

## 🚀 Getting Started

### Requirements

- **macOS 14 Sonoma** or later
- **Xcode 15+** with Swift 5.9+
- A Spotify and/or Apple Music account

### Build & Run

```bash
# Clone the repo
git clone https://github.com/ParthG2209/Resona.git
cd Resona

# Open in Xcode
open Resona.xcodeproj

# Build and run (⌘R)
```

### First Launch

1. Resona appears in your **menu bar** (no Dock icon).
2. Click the menu bar icon → connect **Spotify** and/or **Apple Music**.
3. For **Spotify**: you'll be redirected to authorize via browser. The OAuth callback (`resona://callback/spotify`) handles the rest.
4. For **Apple Music**: macOS will prompt you to allow Resona to control Music.app. Click **Allow**.
5. Play a song — your wallpaper comes alive! 🎶

---

## 🔧 Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Wave Intensity | 50% | Controls fluid animation speed (0 = still, 100% = full motion) |
| Animated Wallpapers | On | Toggle between animated (Metal) and static (composed image) mode |
| Transition Style | Fade | Fade (2s) or Instant wallpaper transitions |
| On Music Stop | Keep Last Art | Keep the last wallpaper or revert to your original |
| Cache Size | 500 MB | Maximum artwork cache size on disk |
| Clear Cache on Quit | Off | Auto-delete cached artwork when Resona closes |

All settings are accessible from **Menu Bar → Settings** (⚙️).

---

## 🏗 Architecture

```
Resona/
├── App/
│   └── ResonaApp.swift           # Entry point, AppDelegate, menu bar setup
├── Models/
│   ├── Track.swift               # Unified track model (id, name, artist, artwork)
│   ├── AppSettings.swift         # UserDefaults-backed preferences
│   ├── Artwork.swift             # Artwork metadata
│   └── SpotifyModels.swift       # Spotify API response models
├── Services/
│   ├── MusicDetectionService.swift    # Central coordinator (conflict resolution)
│   ├── SpotifyService.swift           # Spotify OAuth + Web API polling
│   ├── SpotifyCanvasService.swift     # Canvas video fetching (unofficial API)
│   ├── AppleMusicService.swift        # AppleScript + notification-based detection
│   ├── WallpaperManager.swift         # Routes to animated vs static mode
│   └── AnimatedWallpaperController.swift  # Metal shader engine + color extraction
├── UI/
│   ├── MenuBarView.swift         # Menu bar dropdown UI
│   ├── SettingsView.swift        # Settings window (tabs)
│   ├── ServiceConflictView.swift # "Both playing" conflict dialog
│   └── DefaultWallpaperPickerView.swift  # First-launch wallpaper selection
├── Cache/
│   └── ArtworkCache.swift        # Disk-based artwork caching
└── Utilities/
    ├── Constants.swift           # API keys, endpoints, configuration
    ├── KeychainManager.swift     # Secure credential storage
    ├── Logger.swift              # Categorized logging
    └── URLSchemeHandler.swift    # OAuth callback URL handler
```

### Key Technical Details

| Component | Technology |
|-----------|-----------|
| Fluid Animation | Metal fragment shader with simplex noise + domain warping |
| Color Extraction | `CIAreaAverage` on 3×3 grid → farthest-first distinct selection + saturation boost |
| Spotify Auth | OAuth 2.0 PKCE flow with Keychain-stored tokens |
| Spotify Canvas | Unofficial protobuf API via `sp_dc` cookie + TOTP |
| Apple Music Detection | `DistributedNotificationCenter` + AppleScript polling |
| Apple Music Artwork | `NSAppleScript` → `raw data of artwork 1` from Music.app |
| Window Management | `NSWindow` at `.desktop` level, zero UI chrome |
| Video Playback | `AVQueuePlayer` + `AVPlayerLooper` for seamless Canvas loops |
| Settings Storage | `UserDefaults` via `@UserDefault` property wrapper |
| Credentials | macOS Keychain via Security framework |

---

## 🎨 The Shader

Resona's fluid wallpaper is powered by a real-time **Metal fragment shader** that:

1. **Simplex Noise** generates organic, flowing patterns
2. **Double Domain Warping** adds fluid-like distortion (the "flowing" effect)
3. **5-Color Palette Blending** smoothly interpolates between the album's extracted colors
4. **Radial Vignette** adds depth with a subtle darkening at the edges
5. **Wave Intensity** is user-controllable via a uniform slider

The color palette is extracted using a **hybrid approach**:
- `CIAreaAverage` samples 10 regions (3×3 grid + center crop)
- **Farthest-first selection** picks the 5 most visually distinct colors
- A 20% **saturation boost** ensures vibrant fluid rendering
- `diversifyIfNeeded` handles monochromatic covers by generating hue/brightness variations

---

## 🎵 Spotify Canvas

Spotify Canvas is a feature where artists can attach a short looping video to their tracks. When available, Resona plays the Canvas video as your wallpaper instead of the fluid animation.

This uses Spotify's **unofficial internal API**, which requires:
1. Your `sp_dc` cookie (extracted from the Spotify web player)
2. A TOTP-based authentication flow

> ⚠️ Canvas support uses undocumented Spotify endpoints and may stop working at any time.

---

## 🍎 Apple Music (No Developer Membership Required)

Unlike other apps that require a $99/year Apple Developer Program membership for MusicKit, Resona uses a **free** approach:

| Step | Method |
|------|--------|
| Detect track changes | `DistributedNotificationCenter` → `com.apple.Music.playerInfo` |
| Get track metadata | Notification `userInfo` (name, artist, album, state) |
| Poll as fallback | AppleScript queries Music.app every 2 seconds |
| Get album artwork | `NSAppleScript` → `raw data of artwork 1 of current track` |

The only requirement is granting **Automation permission** when prompted ("Resona wants to control Music").

---

## ⚠️ Known Limitations

- **Spotify Canvas** depends on unofficial APIs — may break with Spotify updates.
- **Apple Music artwork** requires Music.app to be running (not just the web player).
- **macOS Sandbox**: If distributed via the Mac App Store, AppleScript automation may be restricted. The app is designed for direct distribution.
- **Energy Impact**: The Metal shader runs at 60fps. On laptops running on battery, consider using Static mode.

---

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with ❤️ and Metal shaders by <a href="https://github.com/ParthG2209">Parth Gupta</a></sub>
</p>
