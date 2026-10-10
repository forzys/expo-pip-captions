# Changelog

## 0.6.1

- iOS: the video keeps playing when the app goes to the background, and playback is resumed if the system paused it while loading or while Picture in Picture was starting.

## 0.6.0

- iOS: `video.systemControls` switches to the regular video Picture in Picture with the system transport controls (no subtitles or danmaku in that mode).
- iOS: `video.paused` is applied only when its value changes.

## 0.5.0

- `captionPosition` (`top` / `bottom`) for subtitles shown with a video.
- Danmaku: `sendFloatingDanmakuAsync` and the `danmaku` options, separate from subtitles.

## 0.4.0

- `press` event when the user taps the window.
- `iosTapBehavior` (`stop` / `keep`) and `androidTapBehavior` (`none` / `openApp`).

## 0.3.1

- iOS: the video layer is only created while a video is set, so a captions-only window is unchanged from 0.2.0.
- iOS: events carry `appState`.

## 0.3.0

### Added

- Video playback in the floating window through the `video` option, with captions over it (iOS) or below it (Android).
- `seekFloatingVideoAsync`, `videoReady` / `videoEnd` / `videoError` events and `status.video` (playing, position, duration).

### Changed

- `updateFloatingCaptionAsync` merges `video` and `appearance` one level deep.
- With a video, the placeholder is only shown when `placeholder` is passed explicitly.

## 0.2.0

First public release. Compared with the in-app 0.1.0 module:

### Added

- `addFloatingCaptionListener` with `start`, `stop` (including `userInitiated`) and `error` events.
- Options: `captionMode`, `maxVisibleItems`, `placeholder`, `showIcon`, `iconName`, `showDuration`, `appearance` (colors, font size, corner radius), `showCloseButton`, `draggable`, `position`, `iosAudioSession`.
- Config plugin that adds the `audio` background mode on iOS.
- iOS: native duration ticker driven by `durationMs`, matching Android.
- Android: `PipCaptionsModule.updateFromNative` for native pipelines.
- Default export `PipCaptions` with short method names.

### Changed

- Native module is now named `ExpoPipCaptions`; Android package is `expo.modules.pipcaptions`.
- `updateFloatingCaptionAsync` merges into the current snapshot instead of replacing it.
- `durationLabel` is rendered as-is on both platforms and only when `durationMs` is absent. Android used to parse it into a running timer.
- The header icon defaults to the app icon on both platforms; no logo is bundled.
- iOS deployment target lowered from 16.2 to 15.1.
- Native functions run on the main thread on both platforms.

### Fixed

- iOS: a pending start retry no longer reopens Picture in Picture after `stopFloatingCaptionAsync`.
- Android: the overlay is removed when the module is destroyed, and can no longer be dragged off screen.
