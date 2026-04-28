# AudioCDBurner

A simple, native macOS app for burning Red-Book audio CDs from MP3 / FLAC / AAC / M4A / WAV / AIFF / ALAC files. Written in Swift + SwiftUI, using Apple's `DiscRecording.framework`.

Author: **Robert Vloothuis** (`rvlo`)
Bundle ID: `rvlo.AudioCDBurner`

## Features

- Drag & drop or "Add Files…" import (FLAC, MP3, AAC, M4A, WAV, AIFF, ALAC)
- Numbered track list, reorderable, with per-track duration
- Live total-time display with 80-min capacity warning (soft warning at 79:30)
- Disc title (CD-Text), capped to 64 characters
- Gap mode: **2 second gap** (Red-Book default) or **Gapless**
- Auto-discovers CD/DVD burners; "Rescan" button picks up drives plugged in after launch
- Per-drive supported burn-speed picker, plus "Max"
- Auto-eject when the burn finishes (and on failure)

## Building

1. Open `AudioCDBurner.xcodeproj` in Xcode 15 or newer.
2. Select the **AudioCDBurner** target → **Signing & Capabilities** → set your **Team**.
   - Bundle identifier is `rvlo.AudioCDBurner`. Change it if you prefer.
   - "Automatically manage signing" works fine for personal/Developer ID signing.
3. Choose **My Mac (Apple Silicon)** as the run destination and press ⌘R.

Deployment target is **macOS 14**, so it runs on Sonoma, Sequoia, and Tahoe. Apple Silicon native; Intel still works (universal binary by default).

## Notes / design

- All input files are decoded once into a temporary AIFF in CD-DA format
  (44.1 kHz, 16-bit signed big-endian, stereo) using AVFoundation +
  AudioToolbox. This makes FLAC/MP3/AAC/etc. work uniformly through
  `DRTrack(forAudioOfURL:)` and gives exact sector counts.
- Gapless mode sets `DRPreGapLengthKey = 0` on tracks 2…N and
  `DRAudioPreGapIsSilentKey = false` so consecutive tracks are joined
  without silence (track 1 still has the standard 2-second pre-gap that
  the Red-Book spec requires).
- 2-second mode leaves the default 150-frame pre-gap untouched.
- Speed `0` in the picker means "let the drive use its maximum"
  (`DRDeviceBurnSpeedMax`). Other values are taken from
  `DRDeviceBurnSpeedsKey` of the currently inserted disc.
- The disc title is attached to the first track via
  `DRCDTextSpecialAlbumKey`, which DiscRecording uses to populate the
  CD-Text album field.
- The app is sandboxed with `com.apple.security.device.optical-drive`
  and `com.apple.security.files.user-selected.read-only`, so it has
  exactly the entitlements it needs and nothing more.

## Limitations / things to know

- DiscRecording itself does not let you append to a multi-session audio
  CD; this app always burns a single closed audio session, which is
  what every consumer CD player expects.
- macOS sandbox + DiscRecording require the user to actually click
  "Burn" with a writable disc inserted; nothing in this app burns
  silently.
- If you want per-track CD-Text (title/performer per track), the
  framework supports it via `DRCDTextSpecialPerformerKey` /
  `DRCDTextSpecialTitleKey` on each `DRTrack`. The current UI is
  intentionally minimal (disc title only).
