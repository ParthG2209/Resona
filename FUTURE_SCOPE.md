# Resona: Future Scope & Design Document

## 1. Executive Summary
Resona is transitioning from a simple macOS background utility into a highly immersive, premium desktop music experience. The next major phase ("v2") will introduce centered dynamic layouts, mathematically driven fluid textures, synchronized karaoke-style lyrics, and simulated beat reactivity. Most notably, it will unify the Apple Music and Spotify experiences, bringing Spotify's database (including Canvas videos and audio metadata) to Apple Music listeners automatically.

---

## 2. Core Feature Specifications

### 2.1 Dynamic Centered UI (The Morphing Canvas)
*   **Current State:** Blurry, full-screen Canvas videos or static wallpapers.
*   **New Design:** The fluid shader always serves as the base layer desktop background. In the center of the screen, a premium UI "shape" will float holding the media.
*   **Behavior:** The center shape smoothly morphs based on the playing media:
    *   **1:1 Square:** For standard, high-resolution album art.
    *   **9:16 Vertical Rectangle:** When a Spotify Canvas video loop is available.

### 2.2 Synchronized "Karaoke" Lyrics
*   **Design:** A sleek, scrolling lyrics view positioned side-by-side with the central album art/canvas shape.
*   **Implementation:** 
    *   Utilizes third-party, free community APIs (e.g., **LRCLIB**) to fetch time-stamped `.lrc` files.
    *   The app reads the timestamps against the track's current playback progress to automatically scroll and highlight the active line.

### 2.3 Intelligent Fluid Textures
*   **Design:** The fluid background's mathematical properties (roughness, smoothness, speed, viscosity) will change per song to match the "vibe" of the music and the album art.
*   **Implementation:** A hybrid approach using:
    1.  **Real-Time Computer Vision:** `CoreImage` filters analyze the album cover for high-frequency noise (grain), edge density, and contrast.
    2.  **Spotify Audio Features:** The API provides metadata like "acousticness" and "energy". 
    *   *Example:* A high-acoustic acoustic guitar track with a grainy vintage cover will result in slow, rough, matte fluid. An electronic stadium track with neon art will result in fast, slick, glassy fluid.

### 2.4 Simulated Audio-Reactivity (The Metronome)
*   **Goal:** The fluid shader "pulses" and reacts to the beat of the song.
*   **Constraint Avoidance:** To bypass macOS's draconian `ScreenCaptureKit` permissions and keep the app lightweight, Resona will *not* listen to actual system audio.
*   **Implementation:** The app fetches the **BPM and Tempo** from the Spotify Web API. An internal `CADisplayLink` mathematically pulses the fluid shader in time with the fetched BPM, creating the illusion of a highly reactive visualizer.

### 2.5 Apple Music Parity via Spotify's Backend
*   **Problem:** iTunes Search API frequently returns incorrect album art (e.g., right song, wrong album/compilation).
*   **Solution:** When an Apple Music track plays, Resona takes the Title and Artist and executes a search against the **Spotify Web API**.
*   **Benefits:**
    *   Flawless, high-resolution 4K album art for Apple Music.
    *   **Apple Music users get Canvas Videos!** The Spotify search returns the Canvas URL, allowing Apple Music to display the looping videos.
    *   Access to Spotify's Audio Features (BPM, acousticness) for the fluid texture math and beat reactivity.

### 2.6 The "Invisible" Desktop Info Panel
*   **Design:** The centered album art / canvas on the desktop remains cleanly visual. However, hovering the mouse cursor over the fluid art gracefully fades in a localized, premium glassmorphic overlay.
*   **Content:** This overlay displays beautifully formatted typography detailing the exact Song Title, Artist, and Album Name. It acts as a passive "What's playing?" peek without permanently cluttering the desktop with buttons.

### 2.7 Menu Bar Command Center Redesign
*   **Design:** A complete structural and visual overhaul of the Resona dropdown menu. It avoids duplicating macOS's native mini-player (removing redundant, heavy playback buttons).
*   **Purpose:** The menu bar drop-down becomes the dedicated power-user and social hub. 
*   **Features:**
    *   Vibrant, glassmorphic layout cleanly displaying the current track metadata and album cover at the top.
    *   **The Dash (Power Controls):** Native UI toggles for adjusting background fluid intensity, forcing "Deep Sleep / Battery Saver" modes, and enabling/disabling Desktop Lyrics.
    *   **The Social Minimalist:** One-click rich sharing integrations (e.g., "Copy Spotify URL", "Share to X", or Last.fm scrobbling hooks).

### 2.8 Comprehensive Multi-Monitor Support
*   **Design Goal:** Ensuring the visual experience translates immaculately to developers and power users with dual monitors or ultra-wide external displays.
*   **Considered Implementations (TBD):**
    1.  **The Clone (Mirrored Sync):** Resona actively mirrors the exact same fluid canvas and centered album art squarely on all connected screens. All visual transitions fire globally at the exact exact moment.
    2.  **The Extension (Panoramic Fluid):** The mathematical fluid shader mathematically spans *across* all monitors as a single unbroken, massive visual ecosystem. However, heavy media (the 9:16 Canvas video or 1:1 Album art) remains centered solely on the primary display.

### 2.9 Deep macOS Ecosystem Integrations
*   **The Native Screensaver:** Resona acts as an official macOS Screensaver module. When the computer is locked or idle, the fluid and album art continue to animate as a living gallery piece for the room.
*   **Apple Focus Filters:** Direct integration with macOS Focus Modes. For example, triggering "Do Not Disturb" or "Work Focus" can automatically tell Resona to enter a muted, distraction-free aesthetic (dimming colors, lowering FPS, and pausing moving 9:16 canvases).
*   **Siri & Shortcuts App Hooks:** Exposing Resona's power toggles to the native Shortcuts app. This allows users to build robust automations (e.g., "When AirPods connect, launch Spotify and start Resona on High Intensity").

---

## 3. Technical Constraints & Architecture Decisions

### 3.1 Managing Spotify API Rate Limits for Apple Music Users
*   **Problem:** Using a single hardcoded Spotify App Client ID (Client Credentials Flow) for all Apple Music users will result in HTTP 429 (Too Many Requests) errors as the app scales, because rate limits are applied to the App ID, not the anonymous user.
*   **Solutions for Implementation:**
    1.  **Require a Free Spotify Account (Recommended for Scale):** Approach Apple Music users to link a free Spotify account. This switches routing to the **Authorization Code Flow**, giving every individual user their own rate limit bucket and avoiding API exhaustion completely.
    2.  **"Bring Your Own Key" (Power User Fallback):** Add a "Developer Options" tab where advanced users can paste their own Spotify `Client_ID` and `Client_Secret` from the developer dashboard.
    3.  **Unofficial Web API Endpoints (The Anonymous Route):** Utilize undocumented endpoints used by Spotify's web player, which rely on temporary anonymous tokens and bypass standard developer rate limits. This is effective but fragile.

### 3.2 Third-Party Lyric Dependency
*   **Decision:** Lyrics rely 100% on LRCLIB or similar community sources.
*   **Why:** Neither Spotify nor Apple Music provide lyrics via their public APIs. 
*   **Fallback:** If LRCLIB fails or missing timestamps, the UI smoothly hides the lyrics panel or displays a static text fallback.

### 3.3 Zero-Permission Architecture
*   **Decision:** Retain the current status of requiring zero aggressive privacy permissions (No Screen Recording, No Microphones). 

---

## 4. Brainstorming Decision Log

| ID | Decision | Alternative Considered | Rationale |
|:---|:---|:---|:---|
| **01** | **Dynamic 1:1 to 9:16 UI Shape** | Force cropping vertical canvases to 1:1 squares, or pillarbox them. | Cropping cuts off the artist's intended video. Pillarboxing looks cheap. A morphing UI shape looks premium, deliberate, and protects the fluid wallpaper aesthetic. |
| **02** | **Simulated Beat Reactivity (BPM Math)** | Requesting macOS Screen / System Audio Recording permissions for true audio analysis. | Users hate granting screen recording permissions to background apps. Simulating the beat via the BPM API achieves 90% of the effect with 0% of the privacy invasion. |
| **03** | **Hybrid Texture Engine (Vision + API)** | Guessing texture solely based on genre or solely based on color palettes. | Genre metadata is often inaccurate. Color palettes alone don't convey "grain". A hybrid approach guarantees a unique fluid feel per track. |
| **04** | **Spotify Backend for Apple Music** | Continuing to patch the iTunes Search API with string sanitization. | iTunes Search is inherently flawed and doesn't provide Canvas/BPM data. Using the Spotify Client Credentials flow brings full feature parity to Apple Music users silently. |
