# WebKit DRM / FairPlay Compatibility

The browser is designed to keep **encrypted media (FairPlay, EME) working exactly like Safari** by using WKWebView and the native WebKit media pipeline. No custom code replaces or intercepts playback or DRM license requests.

## DRM safety requirements (enforced)

- **Do not replace or override WebKit video playback.** All playback uses the native pipeline.
- **Do not intercept DRM license requests.** EME and FairPlay are handled entirely by WebKit.
- **Do not inject scripts into `<video>` playback.** Media-detection scripts only *read* state (e.g. for UI); they do not modify `video.src`, EME, or license flow.
- **Keep hardware acceleration enabled.** No preference disables GPU or hardware-accelerated decoding.
- **Encrypted Media Extensions (EME)** continue to work; we do not disable or override them.

## WKWebView configuration (media / DRM)

In `BrowserConfig.webViewConfiguration`:

- `allowsInlineMediaPlayback = true`
- `mediaTypesRequiringUserActionForPlayback = []`
- Picture-in-Picture, fullscreen, and AirPlay are enabled.
- Media and GPU-related preferences are not disabled.

The same settings are applied in `cacheOptimizedWebViewConfiguration(for:)` so all tabs use a DRM-safe config.

## Cookie requirements (Canvas LMS, Kaltura, DRM)

Third-party cookies can be enabled for sites that need them (e.g. Canvas LMS, Kaltura) so that:

- Login and session cookies work across the main page and embedded iframes.
- DRM-licensed video in iframes (e.g. Kaltura) can authenticate and play.

Tracking protection already excludes Canvas/Kaltura domains from third-party cookie blocking; see `docs/CANVAS_KALTURA_WEBKIT_AUDIT.md`.

## Features that do not affect DRM

- **Overlay loading indicator:** SwiftUI overlay above the web content; no script injection into the page or into `<video>`.
- **Password manager:** Injects only a small script for focus detection and a fill callback; credentials are filled only on **user click** (never automatically). No interaction with media or EME.
- **Sidebar / borderless UI:** Layout and chrome only; no change to WKWebView or media pipeline.

## Summary

FairPlay and EME continue to work because we use the default WebKit media stack, do not intercept licenses, do not inject into video playback, and keep media/GPU features enabled. Third-party cookie allowances for Canvas/Kaltura support both login and DRM video in iframes.
