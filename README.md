# expo-pip-captions

Floating captions and video for Expo and React Native apps.

`expo-pip-captions` renders a small always-on-top window that stays visible after the user leaves your app: the system Picture in Picture window on iOS, a draggable overlay window on Android. It shows rolling captions, a video, or a video with your own captions on top. It is built for live transcription and translation apps that already own the audio / speech pipeline and only need a native surface for the result.

[简体中文](./README.zh-CN.md)

## Platform behavior

| Platform | Implementation | Notes |
| --- | --- | --- |
| iOS 15.1+ | `AVPictureInPictureController` with a video-call content source | The system owns the window: size, position and controls. |
| Android 7+ | `WindowManager` application overlay | The module owns the window: width, position, drag and close button. |
| Web / Expo Go | JS fallback | Every call resolves with `supported: false`. Nothing is rendered. |

This package contains native code, so it needs a [development build](https://docs.expo.dev/develop/development-builds/introduction/). It does not work in Expo Go.

## Installation

```sh
npx expo install expo-pip-captions
```

Add the config plugin to `app.json` / `app.config.js`:

```json
{
  "expo": {
    "plugins": ["expo-pip-captions"]
  }
}
```

Then rebuild the native app (`npx expo prebuild` + `npx expo run:ios` / `run:android`, or a new EAS build).

### What the plugin does

- **iOS**: adds `audio` to `UIBackgroundModes`. Picture in Picture only keeps running while the app is allowed to stay alive in the background. Pass `{ "enableBackgroundAudio": false }` if you already configure background modes elsewhere.
- **Android**: nothing. `SYSTEM_ALERT_WINDOW` is declared in the library manifest and merged automatically.

In a bare React Native project with `expo-modules` installed, skip the plugin and add `audio` to `UIBackgroundModes` in `Info.plist` yourself.

## Usage

```ts
import { Platform } from "react-native"
import {
  addFloatingCaptionListener,
  getFloatingCaptionStatusAsync,
  requestFloatingCaptionPermissionAsync,
  startFloatingCaptionAsync,
  stopFloatingCaptionAsync,
  updateFloatingCaptionAsync,
} from "expo-pip-captions"

async function openCaptions() {
  if (Platform.OS === "android") {
    const status = await getFloatingCaptionStatusAsync()
    if (!status.permissionGranted) {
      // Opens the system "Display over other apps" screen. Call openCaptions()
      // again once the user is back in the app.
      await requestFloatingCaptionPermissionAsync()
      return
    }
  }

  await startFloatingCaptionAsync({
    variant: "regular",
    durationMs: 0,
    items: [],
    placeholder: "Listening...",
    appearance: { backgroundColor: "#121212", textColor: "#FFFFFF" },
  })
}

// Push new text whenever your transcription changes.
function onTranscript(segments: { id: string; text: string; translation?: string }[], elapsedMs: number) {
  updateFloatingCaptionAsync({
    durationMs: elapsedMs,
    items: segments.map((segment) => ({
      key: segment.id,
      text: segment.text,
      translatedText: segment.translation,
    })),
  })
}

// Know when the user closes the window.
const subscription = addFloatingCaptionListener((event) => {
  if (event.type === "stop" && event.userInitiated) {
    console.log("captions dismissed by the user")
  }
})

// Later
subscription.remove()
await stopFloatingCaptionAsync()
```

### Video

Pass `video` to play a video in the same window. Captions keep working and are optional: leave `items` empty for a plain floating player.

```ts
await startFloatingCaptionAsync({
  items: [],
  video: { uri: "https://example.com/talk.m3u8", resizeMode: "contain" },
})

// Control playback
await updateFloatingCaptionAsync({ video: { paused: true } })
await seekFloatingVideoAsync(30_000)

// Swap or remove the video without closing the window
await updateFloatingCaptionAsync({ video: { uri: "file:///path/to/clip.mp4" } })
await updateFloatingCaptionAsync({ video: null })

// Read the playback position
const { video } = await getFloatingCaptionStatusAsync() // { playing, positionMs, durationMs }
```

The same functions are available on the default export: `PipCaptions.startAsync(...)`, `PipCaptions.updateAsync(...)`, `PipCaptions.addListener(...)` and so on.

## API

All functions resolve with a `FloatingCaptionStatus` and never reject for expected conditions (unsupported device, missing permission); check `supported`, `permissionGranted`, `active` and `reason`.

| Function | Description |
| --- | --- |
| `getFloatingCaptionStatusAsync()` | Current status. |
| `requestFloatingCaptionPermissionAsync()` | Android: opens the overlay permission screen when the permission is missing. The result reflects the state *before* the user returns, so re-check when the app comes back to the foreground. iOS: no permission is needed, resolves with the current status. |
| `startFloatingCaptionAsync(options)` | Shows the surface. On iOS Picture in Picture starts asynchronously, so the result usually still says `active: false`; wait for the `start` event. |
| `updateFloatingCaptionAsync(snapshot)` | Merges `snapshot` into the current one and re-renders. Options given to `start` stay in effect unless overridden. |
| `pauseFloatingCaptionAsync(paused)` | Freezes / resumes the native duration ticker. It does not pause the video; use `update({ video: { paused } })`. |
| `seekFloatingVideoAsync(positionMs)` | Seeks the video. |
| `stopFloatingCaptionAsync()` | Removes the surface. |
| `addFloatingCaptionListener(listener)` | Subscribes to `start`, `stop`, `error`, `videoReady`, `videoEnd` and `videoError` events. Returns `{ remove() }`. |

### Snapshot

```ts
type FloatingCaptionSnapshot = FloatingCaptionOptions & {
  items: FloatingCaptionSegment[]
  durationMs?: number      // native side keeps ticking from this value
  durationLabel?: string   // preformatted label, used only when durationMs is absent
  isPaused?: boolean
}

type FloatingCaptionSegment = {
  key: string
  text: string                    // original text
  translatedText?: string | null  // preferred over `text` in the default caption mode
  displayText?: string | null     // fallback when both of the above are empty
}
```

Duration label rules, identical on both platforms:

1. `durationMs` given: the native side renders `m:ss` / `h:mm:ss` and keeps it ticking by itself, so it stays correct while JS is suspended in the background. Within one session the clock never moves backwards.
2. Otherwise, `durationLabel` given: rendered as-is.
3. Neither: counts up from `0:00` since `start`.

### Options

Pass these to `start`, or to `update` to change them on the fly.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `variant` | `"regular" \| "mini"` | `"regular"` | Size preset. |
| `captionMode` | `"auto" \| "original" \| "bilingual"` | `"auto"` | `auto`: translation, falling back to original. `original`: original, falling back to translation. `bilingual`: original with the translation on the next line. |
| `maxVisibleItems` | `number` | `5` | How many of the latest `items` are rendered. |
| `placeholder` | `string` | `"Listening..."` | Shown while there is nothing to render. |
| `showIcon` | `boolean` | `true` | Header icon. |
| `iconName` | `string` | app icon | iOS: image name in the app bundle / asset catalog. Android: drawable or mipmap resource name. |
| `showDuration` | `boolean` | `true` | Header duration label. |
| `video` | `FloatingCaptionVideo \| null` | none | See below. |
| `appearance.backgroundColor` | color string | `#121212` | Any React Native color string. |
| `appearance.textColor` | color string | `#FFFFFF` | Caption color. |
| `appearance.durationColor` | color string | white, 62% | Duration label (and Android close icon). |
| `appearance.fontSize` | `number` | `19` / `15` (mini) | Caption font size. |
| `appearance.cornerRadius` | `number` | platform preset | Corner radius. |
| `showCloseButton` | `boolean` | `true` | Android only. |
| `draggable` | `boolean` | `true` | Android only. Drag by the header. |
| `position` | `{ x, y }` in dp | `{ x: 16, y: 120 }` | Android only. Initial top-left position. |
| `iosAudioSession` | `"playAndRecord" \| "playback" \| "none"` | `"playAndRecord"` | iOS only. See below. |
| `iosTapBehavior` | `"stop" \| "keep"` | `"stop"` | iOS only. See [Taps](#taps). |
| `androidTapBehavior` | `"none" \| "openApp"` | `"none"` | Android only. See [Taps](#taps). |

### Video options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `video.uri` | `string` | required | Remote URL (mp4, HLS, ...), `file://` URL or absolute file path. Changing it loads the new video. |
| `video.headers` | `Record<string, string>` | none | HTTP headers for remote requests. |
| `video.paused` | `boolean` | `false` | Playback starts as soon as the video is ready. |
| `video.muted` | `boolean` | `false` | |
| `video.volume` | `number` | `1` | 0 to 1. |
| `video.loop` | `boolean` | `false` | |
| `video.positionMs` | `number` | `0` | Start position, applied once per `uri`. |
| `video.resizeMode` | `"contain" \| "cover"` | `"contain"` | |

How the window is laid out with a video:

- **iOS**: the video fills the PiP window, which takes the video's aspect ratio. Captions are drawn over the bottom edge on a dark scrim, at most 3 lines (2 for `mini`). The header (icon, duration) is hidden.
- **Android**: the video sits between the header and the captions, at the video's aspect ratio. The caption area uses the compact height.
- Without caption text, the caption area is hidden; the placeholder only shows if you pass `placeholder` explicitly.

### Taps

A tap on the window emits a `press` event on both platforms, so the app decides what it means (navigate to a screen, pause, show controls in the app, ...).

```ts
addFloatingCaptionListener((event) => {
  if (event.type === "press") {
    navigation.navigate("LiveTranscript")
  }
})
```

What else happens differs, because the platforms give apps different amounts of control:

- **iOS**: the system brings the app to the foreground on every tap. This cannot be turned off or replaced. `iosTapBehavior` only decides what happens to the session: `stop` (default) closes the window, `keep` leaves the session alive so the window reappears by itself the next time the app goes to the background (the `stop` event then carries `resumable: true`). `press` is also emitted when iOS restores the app from the window in other ways.
- **Android**: nothing happens by default; `press` is yours to handle, and the app can stay in the background. `androidTapBehavior: "openApp"` additionally brings the app to the foreground. Taps on the captions and the video count; the header remains the drag handle.

### Events

```ts
type FloatingCaptionEvent = {
  type: "start" | "stop" | "press" | "error" | "videoReady" | "videoEnd" | "videoError"
  userInitiated?: boolean  // stop: closed by the user rather than by stopFloatingCaptionAsync()
  resumable?: boolean      // iOS stop after a tap with iosTapBehavior "keep"
  message?: string         // error, videoError
  status: FloatingCaptionStatus
}
```

## Platform notes

### iOS

- The final size of the PiP window is decided by iOS. `variant` only provides a preferred size and aspect hint.
- PiP content is not interactive. Taps are handled by the system and return to the app (see [Taps](#taps)), so there is no custom close button; users close the window with the system controls, which emits `stop` with `userInitiated: true`.
- PiP can only start while the app is in the foreground and has an active, non-ambient audio session. If the session category is still `ambient` / `soloAmbient` when you call `start`, the module switches it to `playAndRecord` (or `playback`, per `iosAudioSession`) with `mixWithOthers`. If your app already configures the session (for example through a recording library), it is left untouched apart from being activated. Use `iosAudioSession: "none"` to opt out completely.
- Video plays inside a video-call style PiP window, which is what allows custom captions on top of it. The trade-off is that the system play / pause / skip buttons are not available; control playback from your app.
- Starting can take a moment right after launch or after returning to the foreground; the module retries for about 1.6 seconds, then emits `error`.

### Android

- "Display over other apps" must be granted by the user in system settings. There is no in-app dialog for it.
- Video is played with the platform `MediaPlayer`, so format support is whatever the device supports (mp4 / H.264 and HLS work broadly; DRM and DASH do not). Remote playback needs the `INTERNET` permission, which React Native apps have by default.
- The close button removes only the overlay and emits `stop` with `userInitiated: true`. Whether transcription should also stop is up to your app.
- When JS is suspended in the background, a native pipeline can keep the overlay updated directly:

  ```kotlin
  import expo.modules.pipcaptions.PipCaptionsModule

  PipCaptionsModule.updateFromNative(
    mapOf(
      "durationMs" to elapsedMs,
      "items" to listOf(mapOf("key" to "1", "text" to "Hello", "translatedText" to "你好")),
    )
  )
  ```

  It accepts the same keys as `updateFloatingCaptionAsync` (colors as ARGB ints), can be called from any thread, and is ignored until the surface has been started from JS.

## What this package does not do

Speech recognition, translation, audio capture and subtitle file parsing (SRT / VTT) are out of scope. The module only renders the snapshots you give it; to subtitle a video, push the cue for the current position with `updateFloatingCaptionAsync`. Captions are never stored or sent anywhere by this package.

## Requirements

- Expo SDK 53 or newer (developed and tested against SDK 55 / React Native 0.83)
- iOS 15.1+, Android 7.0+ (API 24)

## Contributing

```sh
npm install
npm run typecheck
npm run build
```

To try native changes, install the package into an Expo app from a local path (`npx expo install expo-pip-captions@file:../expo-pip-captions`) and rebuild that app.

## License

MIT
