# Resona: Engine Optimization & Fixes Plan

## 1. Executive Summary
This document outlines the architectural overhauls required to fix the five core issues present in the Resona v1 engine. The primary goals are eliminating severe overheating (M-series thermal throttling), fixing UI flashing during song transitions, repairing the debouncer for fast skipping, and ensuring bulletproof reliability when Spotify or Apple Music restarts. No visual tradeoffs will be made to achieve these performance gains.

---

## 2. Issue Diagnoses & Solutions

### Issue 1: Severe Overheating (70-80°C on MacBook Air)
*   **Context:** Rendering full-screen complex fluid shaders natively at 60fps cooks passively cooled M-Series chips over time.
*   **Solution (Invisible Backend Optimizations):**
    1.  **Internal Resolution Downscaling:** The mathematical fluid gradients will render at a 50%-75% target resolution and use Apple's hardware filtering to upscale instantly to the Retina display. The visual identicality remains 100%, but GPU fill-rate drops by 4x.
    2.  **Zero-Idle CPU Loops:** Complete rewrite of the `Combine` pipelines to guarantee 0% CPU usage when the music is paused.
    3.  **MTKView Texture Recycling:** Stop recreating images in RAM on every frame change. The GPU will cycle the same blocks of VRAM forever.

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

---

## 3. Brainstorming Decision Log

| ID | Issue | Decision Chosen | Alternative Rejected | Rationale |
|:---|:---|:---|:---|:---|
| **01** | Performance | **Invisible Engine Optimizations** | Dropping FPS to 30 or reducing fluid complexity. | A premium app shouldn't compromise on smoothness or quality. Internal resolution scaling and smart polling achieve the thermal drop invisibly. |
| **02** | Visual Flashes | **AutoMix Double-Buffering** | Taking a static screenshot (Freeze Frame) or Fading to a solid color. | Crossfading two living textures is intensive but makes the app feel like a true dynamic ocean. The desktop must remain entirely hidden. |
| **03** | Rapid Skips | **Patient Listener (Strict Debounce)** | Instant response with aggressive network cancellation. | A 0.8s strict debounce cleanly protects the Network/GPU from thrashing when the user is trying to find a song they like. |
| **04** | Spotify Restarts | **Deep Sleep Hibernation** | Blindly auto-retrying failed Combine publishers. | Sleeping when not in use is macOS best practice. Destroying and properly rebuilding the visual pipeline guarantees no memory leaks over days of uptime. |
