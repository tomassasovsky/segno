# Segno Transfer 0.3.0

A small Mac companion for your Segno appliance: browse performance recordings,
stream audio with seeking, and download selected files with names you choose.

## What's new

- **Open in Live** downloads a performance's Live set, with every recording,
  loop and stem it uses, verifies each file and opens it in Ableton Live in one
  click. A second click opens the verified copy without downloading it again.
- **Segno plugins included.** The app carries `Segno.vst3`, the console's
  effects with their pedal faces. When a set needs them and they are missing
  or older, **Open in Live** offers to install them into
  `~/Library/Audio/Plug-Ins/VST3`, and replaces an older copy only if you
  confirm. **Plug-ins > Install Segno Plugins** does the same at any time.
  After installing, rescan plug-ins in Live or restart it. If macOS says it
  cannot verify `Segno.vst3`, approve it in **System Settings → Privacy &
  Security** with **Open Anyway**, as for the app.

## Download and install

Requires **macOS 14 or newer and Apple Silicon (M1 or newer)**.

1. Download **Segno-Transfer-0.3.0-macos-arm64.dmg** below.
2. Open the disk image and drag **Segno Transfer** into **Applications**.
3. Open the app from Applications.

This free release is locally signed and is **not notarized by Apple**. If macOS
blocks its first launch, dismiss the warning, open **System Settings → Privacy &
Security**, then choose **Open Anyway** for Segno Transfer and confirm.
[Apple's first-launch instructions](https://support.apple.com/en-us/102445).

## Use

Enter your appliance address and click **Connect**. The app uses the Mac's
existing SSH keys and trusted appliance identity; a new pairing needs SSH setup
first. Password entry and first-time pairing are not included in this version.

- Preview files with **Play**, **Pause** and the seek bar. Playback streams
  sections as needed instead of waiting for a complete download.
- Select performances or individual inputs, loops and rendered tracks.
- Edit **Save as**, choose a folder and download verified copies.
- Existing filenames get a numbered suffix; original appliance files stay intact.

The disk image includes installation instructions and the project license.
**SHA256SUMS** contains its download checksum. Source archives are attached by
GitHub and correspond to this release tag.
