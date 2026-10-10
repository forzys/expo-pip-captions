# Changelog

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
