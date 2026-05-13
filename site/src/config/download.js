/**
 * Download configuration for Resona.
 *
 * SETUP STEPS:
 * 1. Go to https://formspree.io → Sign up free → New Form
 * 2. Copy your form endpoint (looks like https://formspree.io/f/abcdefgh)
 * 3. Paste it as FORMSPREE_ENDPOINT below
 *
 * 4. Update DOWNLOAD_URL when you upload your DMG to GitHub Releases:
 *    → Go to your GitHub repo → Releases → Draft a new release
 *    → Upload dist/Resona.dmg → copy the asset URL → paste below
 */

// ── STEP 1: Paste your Formspree endpoint here ──
export const FORMSPREE_ENDPOINT = 'https://formspree.io/f/mjglzaze';

// ── STEP 2: Update this URL when you upload a new DMG ──
export const DOWNLOAD_URL = 'https://github.com/ParthG2209/Resona/releases/download/0.1.0-alpha/Resona.dmg';

// Metadata shown on the download button
export const DOWNLOAD_META = {
  version: '0.1.0-beta',
  platform: 'macOS',
  arch: 'Apple Silicon',
  size: '~48 MB',
};
