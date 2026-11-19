---
title: Two fixes for ivi-homescreen
date: 2026-11-17
summary: Segno's two screens turned up two bugs in ivi-homescreen, the Flutter embedder Segno runs on. One ignored a screen's pixel ratio, the other crashed the app on most shutdowns. Both fixes are now merged upstream.
---

Segno's interface runs on [ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen), the Flutter embedder that Toyota Connected maintains for embedded Linux. On the console it draws straight to DRM/KMS: no Wayland, no desktop. The console has two screens, a 15.6-inch main screen and a 7-inch readout, and each screen is its own `[[view]]` in the embedder's config with its own Flutter engine. Both engines live in one process and share one Dart VM.

That setup turned up two bugs. I've been carrying a patch for each in Segno's Yocto layer, and this week I sent both upstream:

- [#859](https://github.com/toyota-connected/ivi-homescreen/pull/859): apply the configured pixel ratio to window metrics
- [#860](https://github.com/toyota-connected/ivi-homescreen/pull/860): keep the AOT snapshot mapped after engine shutdown

## Why two engines

Flutter can draw several views from one engine, and ivi-homescreen supports that mode. In ivi-homescreen v3.0, only the first view receives input. The readout is the console's only touchscreen, so as a second view of a shared engine it could never be touched. With one engine per view, each engine is bound to its own output by connector name (`HDMI-A-1`, `HDMI-A-2`), and touch reaches the right view by the input device's name.

The two engines talk through the Dart VM they share. Each one publishes a `SendPort` in the `IsolateNameServer` under a fixed name and looks up the other's, with no plugin involved. The main screen owns the audio engine and all the state. The readout draws what it is sent and reports touches back.

## Fix 1: the readout ignored its pixel ratio

The readout is a 1024x600 panel, and its view is configured with `pixel_ratio = 1.6`, so it should lay out at 640x375 logical pixels. It laid out at 1024x600 instead, with `devicePixelRatio` at 1.0, and everything on it was drawn too small.

The configured ratio did reach the engine, but only as a display property (`View.of(context).display.devicePixelRatio` was 1.6). Flutter lays out with the view's ratio, which comes from the window metrics, and on the backends without a Wayland window (`drm-kms-egl`, `drm-kms-vulkan`, software) the first window metrics always carried 1.0. Only the Wayland window ever changed that value.

The fix stores the configured ratio before the first window metrics are sent. Later resizes and the views added for extra DRM outputs read the same value, so they get it too. Touch input needed no change, because it is already delivered in physical pixels.

## Fix 2: a crash on most shutdowns

Restarting Segno's service crashed the app on the way out. 12 of 16 stops left a core dump, all with the same crashing thread:

```
#0 stub CallNativeThroughSafepoint+0x58
#2 _libcRead.#ffiClosure3+0x70
#3 _readerMain+0xb8
...
#16 stub InvokeDartCode+0xd8
```

`_readerMain` is the isolate that reads the console board's serial link. It spends most of its time blocked in an FFI `read()` with a 100 ms timeout.

When an engine shuts down, ivi-homescreen called `FlutterEngineCollectAOTData` right after `FlutterEngineShutdown`. That unmaps the compiled Dart code. But shutting down an engine stops only its root isolate. Isolates the app started with `Isolate.spawn` keep running, the Dart VM keeps running (the other screen's engine is still on it), and the serial reader is usually sitting inside `read()`. When that call returns, it returns through a stub that is no longer mapped, and the process dies with SIGSEGV.

The fix leaves the AOT data mapped and lets the process exit release it. After the change there were 0 core dumps in 226 stops, and a clean stop takes about 0.35 seconds. One stop on the first patched build hung until systemd killed it. It didn't happen again in the next 150, and I don't know yet whether it's related.

## Testing

Both branches build at ivi-homescreen v3.0 with gcc 14 and clang 19 and pass the project's 44 unit tests, its format, spelling and config-reference checks, and clang-tidy on the changed files. The on-device results above come from Segno's console: a Raspberry Pi 5 running `drm-kms-egl`, with both screens connected.

When this entry was first published, both pull requests were waiting for review, and Segno applied the same two patches in its Yocto layer until they were merged.

## Update, 17 November 2026

Both pull requests were merged upstream on 17 November 2026. Segno now builds ivi-homescreen from the upstream v3.0 branch with both fixes in it, and no longer carries either patch.
