# Resona 🎵

> **Your desktop wallpaper, powered by your music.**  
> Resona automatically sets your macOS desktop wallpaper to the currently playing album artwork from Spotify or Apple Music.

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 12.0 Monterey or later |
| Xcode | 14.0 or later |
| Apple Developer Account | Required for MusicKit & code signing |
| Spotify Developer App | Required for Spotify integration |

---

## Xcode Setup (Step by Step)

### 1. Install Xcode

Download Xcode from the Mac App Store or from [developer.apple.com/xcode](https://developer.apple.com/xcode/).

After installing, open Terminal and run:
```bash
xcode-select --install
```

### 2. Create the Xcode Project

1. Open Xcode → **File → New → Project**
2. Choose **macOS → App**
3. Fill in:
   - **Product Name**: `Resona`
   - **Bundle Identifier**: `com.resona.app`
   - **Language**: Swift
   - **Interface**: SwiftUI
   - **Uncheck** "Include Tests" (add manually later)
4. Choose a location to save

### 3. Add the Source Files

Copy all files from this scaffold into your Xcode project:

```
Resona/
├── App/
│   ├── ResonaApp.swift
│   └── MenuBarManager.swift
├── Services/
│   ├── SpotifyService.swift
│   ├── AppleMusicService.swift
│   ├── MusicDetectionService.swift
│   └── WallpaperManager.swift
├── Models/
│   ├── Track.swift
│   ├── Artwork.swift
│   └── AppSettings.swift
├── Cache/
│   └── ArtworkCache.swift
├── UI/
│   ├── MenuBarView.swift
│   └── SettingsView.swift
└── Utilities/
    ├── Constants.swift
    ├── KeychainManager.swift
    └── Logger.swift
```

In Xcode: right-click your project group → **Add Files to "Resona"** → select all files.

### 4. Configure Info.plist

Replace Xcode's generated `Info.plist` with the one from this scaffold, OR manually add:

| Key | Value |
|-----|-------|
| `LSUIElement` | `YES` (hides from Dock) |
| `CFBundleURLTypes` → URL Schemes | `resona` |
| `NSAppleMusicUsageDescription` | Your privacy string |

### 5. Configure Entitlements

1. In Xcode, select your project → **Signing & Capabilities**
2. Click **+ Capability** and add:
   - **App Sandbox** (enable Network → Outgoing Connections)
   - **MusicKit**
   - **Keychain Sharing** → add `com.resona.app`

### 6. Add Your API Credentials

Edit `Utilities/Constants.swift`:

```swift
// Spotify
static let clientID     = "YOUR_SPOTIFY_CLIENT_ID"
static let clientSecret = "YOUR_SPOTIFY_CLIENT_SECRET"

// Apple Music (MusicKit)
static let teamID = "YOUR_APPLE_TEAM_ID"
static let keyID  = "YOUR_MUSICKIT_KEY_ID"
```

**⚠️ Never commit real credentials to Git.** Use Xcode build configurations or environment variables for production.

### 7. Spotify Developer Setup

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
2. Click **Create App**
3. Set **Redirect URI** to: `resona://callback/spotify`
4. Copy **Client ID** and **Client Secret** → paste in `Constants.swift`

### 8. Apple Music / MusicKit Setup

1. Log in to [developer.apple.com](https://developer.apple.com)
2. Go to **Certificates, Identifiers & Profiles → Keys**
3. Create a new key → enable **MusicKit**
4. Download the `.p8` file → rename to `MusicKitKey.p8`
5. Add to your Xcode project bundle (not in a code group — just drag to project root)
6. Copy your **Key ID** and **Team ID** → paste in `Constants.swift`

### 9. Build & Run

Press **⌘R** in Xcode. Resona will appear in your menu bar.

---

## Architecture Overview

```
ResonaApp (entry)
│
├── AppDelegate
│   └── boots MusicDetectionService + MenuBarManager
│
├── MusicDetectionService          ← central coordinator
│   ├── SpotifyService             ← OAuth + polling (1s interval)
│   ├── AppleMusicService          ← MusicKit + MediaPlayer
│   └── WallpaperManager           ← NSWorkspace wallpaper setter
│
├── ArtworkCache                   ← disk cache (~/Library/Caches)
├── KeychainManager                ← secure token storage
├── AppSettings                    ← UserDefaults preferences
└── Logger                         ← os.log wrapper
```

### Key Flows

**New song detected →**
`SpotifyService / AppleMusicService` → debounce 1s → `MusicDetectionService.applyTrack()` → `WallpaperManager.update()` → cache check → download → `NSWorkspace.setDesktopImageURL()`

**OAuth callback →**
Browser opens → user authorizes → `resona://callback/spotify` URL → `SpotifyService.handleCallback()` → token exchange → Keychain storage → polling starts

---

## Development Roadmap

- **Phase 1 (Current)**: Spotify + Apple Music static artwork, menu bar UI, settings, caching
- **Phase 2**: Fade transitions, service conflict UI, advanced settings polish
- **Phase 3**: Spotify Canvas animated wallpapers, multi-monitor support

---

## Known Limitations

| Feature | Status |
|---------|--------|
| Spotify Canvas (animated) | Phase 3 — unofficial API |
| Apple Music animated artwork | Not available via MusicKit |
| Multi-monitor | Phase 3 |
| macOS native animated wallpaper | Not natively supported; workarounds in Phase 3 |

---

## License

Private / Proprietary — all rights reserved.
