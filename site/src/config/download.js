/**
 * Download configuration for Resona.
 * 
 * Update DOWNLOAD_URL when you upload a new build.
 * The easiest free option is GitHub Releases:
 *   1. Create a repo (or use existing) on GitHub
 *   2. Go to Releases → Draft a new release
 *   3. Upload dist/Resona.dmg as a release asset
 *   4. Copy the asset URL and paste it below
 */

// ── UPDATE THIS URL when you upload a new DMG ──
export const DOWNLOAD_URL = '/Resona.dmg';

// Metadata shown on the download button
export const DOWNLOAD_META = {
  version: '1.0.0-beta',
  platform: 'macOS',
  arch: 'Apple Silicon',
  size: '~48 MB',
};
