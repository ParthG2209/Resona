# Resona: Engine Optimization & Fixes Plan

## 1. Executive Summary
This document outlines the architectural overhauls required to fix the five core issues present in the Resona v1 engine. The primary goals are eliminating severe overheating (M-series thermal throttling), fixing UI flashing during song transitions, repairing the debouncer for fast skipping, and ensuring bulletproof reliability when Spotify or Apple Music restarts. No visual tradeoffs will be made to achieve these performance gains.

---

## 2. Issue Diagnoses & Solutions



### Issue 2 & 3: Original Wallpaper Flashes & Jittery Transitions
*   **Context:** Currently, switching songs drops UI layers or animation frames abruptly, exposing the real macOS desktop and breaking immersion.
*   **Solution (The "AutoMix" Crossfade):**
    *   Implementing a **Double-Buffering** architecture. 
    *   The previous song's fluid and cover art remain 100% active on-screen. Invisibly, the new song's visual data is downloaded and initialized.
    *   Once fully ready, the engine mathematically blends and bleeds the colors of Song A directly into Song B, seamlessly crossfading without ever showing the macOS desktop or an artificial color block.

### Issue 4: Broken Debouncer (0.8s Patient Listener)
*   **Context:** Skipping 3 songs rapidly causes the app to queue up and visually "play out" every skipped song with a brutal delay before settling on the 4th song.
*   **Solution (Strict Debounce & Cancel):**
    *   The detection pipeline will utilize a strict `debounce(for: 0.8, scheduler: DispatchQueue.main)` operator.
    *   Rapid "Next" presses are completely ignored by the visual engine. 
    *   Only when a song has been actively reporting as "playing" for exactly 0.8 seconds will the engine fire the network requests and initiate the heavy "AutoMix" transition.

### Issue 5: Broken Service Upon App Restart
*   **Context:** If Spotify crashes or is closed and reopened, backend logs trace track changes, but the visual screen freezes and requires Resona to restart.
*   **Solution (Self-Healing Deep Sleep):**
    *   The connection from the `MusicDetectionService` to the `WallpaperManager` snaps upon API errors.
    *   We will implement an aggressive **Deep Sleep Mode**. If the user explicitly quits Spotify or Apple Music, Resona catches the `NSWorkspace.didTerminateApplicationNotification`. 
    *   Resona actively destroys the visual layer, sleeps at 0% battery draw, and spins up an observer. When the music app is reopened, the visual pipeline rebuilds itself perfectly with zero user interaction.

### Issue 6: CPU/GPU Bloat & Background Power Draw
*   **Context:** The app continuously renders Metal fluid shaders and pulses UI layers at 60fps even when paused, and runs redundant 2-second AppleScript/Network polling.
*   **Solution (Absolute Zero-Idle Footprint):**
    1.  **3-Tier Engine Modes:** Introduce toggleable modes (Static, Normal/Fluid, Fully-Fledged/Canvas) to grant the user explicit control over rendering intensity.
    2.  **GPU Occlusion / Sleep Hibernation:** Bind the Metal engine's `isPaused` flag to the `playbackState`, `NSWorkspace.screensDidSleepNotification`, system lock events, and window `occlusionState`. If the screen is off, locked, or completely covered by a fullscreen app, the GPU and video decoders drop to **0%**.
    3.  **Nuke AppleScript Polling:** Delete the heavy 2-second AppleScript loop in `AppleMusicService` completely, relying entirely on the native, zero-cost `com.apple.Music.playerInfo` push notifications.
    4.  **Smart Spotify Polling:** Shift to exponential network backoff, capping at 15s polls when paused. If `com.spotify.client` is quit, polling suspends completely via `NSWorkspace`.
    5.  **Destroy WindowServer Thrashing (EXPERIMENTAL):** Remove the infinite `CABasicAnimation` pulsing the ambient album art glow. A clean, static drop-shadow looks just as premium and completely halts 60fps WindowServer repainting when the fluid is paused.

---

## 3. Brainstorming Decision Log

| ID | Issue | Decision Chosen | Alternative Rejected | Rationale |
|:---|:---|:---|:---|:---|
| **02** | Visual Flashes | **AutoMix Double-Buffering** | Taking a static screenshot (Freeze Frame) or Fading to a solid color. | Crossfading two living textures is intensive but makes the app feel like a true dynamic ocean. The desktop must remain entirely hidden. |
| **03** | Rapid Skips | **Patient Listener (Strict Debounce)** | Instant response with aggressive network cancellation. | A 0.8s strict debounce cleanly protects the Network/GPU from thrashing when the user is trying to find a song they like. |
| **04** | Spotify Restarts | **Deep Sleep Hibernation** | Blindly auto-retrying failed Combine publishers. | Sleeping when not in use is macOS best practice. Destroying and properly rebuilding the visual pipeline guarantees no memory leaks over days of uptime. |
| **05** | High GPU Idle | **Pause Engine on Occlusion / Stop** | Letting animation run invisibly in background. | If music is paused, or a fullscreen window (Xcode/Chrome) covers the wallpaper, the GPU must instantly drop to 0W usage. |
| **06** | Heavy Polling | **Push Notifications & 15s Backoff** | Constant 2s polling loops via AppleScript. | Gutting AppleScript completely in favor of native push notifications, and enforcing a 15s max exponential backoff on Spotify bounds logic to absolute essentials. |
| **07** | WindowServer CPU | **Static Ambient Glow** | Infinite `CABasicAnimation` pulsing. | Continuously animating opacity forces WindowServer to composite the screen at 60fps forever. A static glow hits 0 CPU and looks visually identical. |
