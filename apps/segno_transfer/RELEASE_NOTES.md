# Segno Transfer 0.1.0

A small Mac companion for your Segno appliance: browse performance recordings,
stream audio with seeking, and download selected files with names you choose.

## Download and install

Requires **macOS 14 or newer and Apple Silicon (M1 or newer)**.

1. Download **Segno-Transfer-0.1.0-macos-arm64.dmg** below.
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
