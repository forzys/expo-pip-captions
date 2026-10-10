# expo-pip-captions

适用于 Expo / React Native 的悬浮字幕与视频小窗。

`expo-pip-captions` 提供一个离开应用后仍然可见的置顶小窗：iOS 使用系统画中画（Picture in Picture），Android 使用可拖动的悬浮窗。小窗可以显示滚动字幕、视频，或在视频上叠加你自己的字幕。它面向已经自己掌握录音 / 语音识别 / 翻译链路、只需要一个原生界面来展示结果的应用。

[English](./README.md)

## 平台行为

| 平台 | 实现 | 说明 |
| --- | --- | --- |
| iOS 15.1+ | `AVPictureInPictureController`（视频通话内容源） | 窗口由系统掌控：大小、位置、控制按钮。 |
| Android 7+ | `WindowManager` 应用悬浮窗 | 窗口由模块掌控：宽度、位置、拖动、关闭按钮。 |
| Web / Expo Go | JS 兜底 | 所有调用返回 `supported: false`，不渲染任何内容。 |

本库包含原生代码，需要 [development build](https://docs.expo.dev/develop/development-builds/introduction/)，不支持 Expo Go。

## 安装

```sh
npx expo install expo-pip-captions
```

在 `app.json` / `app.config.js` 中加入 config plugin：

```json
{
  "expo": {
    "plugins": ["expo-pip-captions"]
  }
}
```

然后重新构建原生应用（`npx expo prebuild` 后 `npx expo run:ios` / `run:android`，或重新打 EAS 包）。

插件做的事：

- **iOS**：向 `UIBackgroundModes` 添加 `audio`。画中画只有在应用被允许后台存活时才能持续显示。如果你已在别处配置后台模式，可传 `{ "enableBackgroundAudio": false }`。
- **Android**：无需处理。`SYSTEM_ALERT_WINDOW` 已在库的 manifest 中声明并自动合并。

## 使用

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
      // 打开系统“显示在其他应用上层”设置页，用户返回应用后再次调用 openCaptions()
      await requestFloatingCaptionPermissionAsync()
      return
    }
  }

  await startFloatingCaptionAsync({
    variant: "regular",
    durationMs: 0,
    items: [],
    placeholder: "正在聆听...",
    appearance: { backgroundColor: "#121212", textColor: "#FFFFFF" },
  })
}

// 转录内容变化时推送
updateFloatingCaptionAsync({
  durationMs: elapsedMs,
  items: [{ key: "1", text: "Hello", translatedText: "你好" }],
})

// 监听用户关闭
const subscription = addFloatingCaptionListener((event) => {
  if (event.type === "stop" && event.userInitiated) {
    // 用户手动关闭了字幕窗
  }
})

subscription.remove()
await stopFloatingCaptionAsync()
```

### 视频

传入 `video` 即可在同一个小窗里播放视频。字幕照常可用且可选：`items` 留空就是一个纯悬浮播放器。

```ts
await startFloatingCaptionAsync({
  items: [],
  video: { uri: "https://example.com/talk.m3u8", resizeMode: "contain" },
})

// 控制播放
await updateFloatingCaptionAsync({ video: { paused: true } })
await seekFloatingVideoAsync(30_000)

// 不关闭小窗的情况下切换 / 移除视频
await updateFloatingCaptionAsync({ video: { uri: "file:///path/to/clip.mp4" } })
await updateFloatingCaptionAsync({ video: null })

// 读取播放进度
const { video } = await getFloatingCaptionStatusAsync() // { playing, positionMs, durationMs }
```

| 选项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `video.uri` | `string` | 必填 | 网络地址（mp4、HLS 等）、`file://` 地址或绝对路径；改变它会加载新视频。 |
| `video.headers` | `Record<string, string>` | 无 | 网络请求附带的 HTTP 头。 |
| `video.paused` | `boolean` | `false` | 视频就绪后立即播放。 |
| `video.muted` | `boolean` | `false` | |
| `video.volume` | `number` | `1` | 0 到 1。 |
| `video.loop` | `boolean` | `false` | |
| `video.positionMs` | `number` | `0` | 起始位置，每个 `uri` 只应用一次。 |
| `video.resizeMode` | `"contain" \| "cover"` | `"contain"` | |

带视频时的布局：

- **iOS**：视频铺满画中画窗口，窗口比例跟随视频。字幕叠在底部的半透明遮罩上，最多 3 行（`mini` 为 2 行），顶部栏（图标、时长）隐藏。
- **Android**：视频位于顶部栏和字幕之间，比例跟随视频，字幕区使用紧凑高度。
- 没有字幕文字时字幕区隐藏；只有显式传入 `placeholder` 才显示占位文字。

事件新增 `videoReady` / `videoEnd` / `videoError`。

## API

所有函数都返回 `FloatingCaptionStatus`，对可预期的情况（设备不支持、缺少权限）不会 reject，请检查 `supported`、`permissionGranted`、`active`、`reason`。

| 函数 | 说明 |
| --- | --- |
| `getFloatingCaptionStatusAsync()` | 当前状态。 |
| `requestFloatingCaptionPermissionAsync()` | Android：缺少权限时打开悬浮窗权限设置页，返回值是用户返回**之前**的状态，回到前台后需重新查询。iOS：无需权限，直接返回当前状态。 |
| `startFloatingCaptionAsync(options)` | 显示字幕窗。iOS 画中画为异步启动，返回值通常仍是 `active: false`，请等待 `start` 事件。 |
| `updateFloatingCaptionAsync(snapshot)` | 将 `snapshot` 合并进当前快照并重新渲染；`start` 时传入的选项持续生效，除非在此覆盖。 |
| `pauseFloatingCaptionAsync(paused)` | 暂停 / 恢复原生计时。不会暂停视频，暂停视频请用 `update({ video: { paused } })`。 |
| `seekFloatingVideoAsync(positionMs)` | 跳转视频进度。 |
| `stopFloatingCaptionAsync()` | 移除字幕窗。 |
| `addFloatingCaptionListener(listener)` | 订阅 `start` / `stop` / `error` / `videoReady` / `videoEnd` / `videoError` 事件，返回 `{ remove() }`。 |

时长显示规则（双端一致）：

1. 传了 `durationMs`：原生侧渲染 `m:ss` / `h:mm:ss` 并自行走时，JS 在后台被挂起时也保持准确；同一会话内只增不减。
2. 否则若传了 `durationLabel`：原样显示。
3. 都没传：从 `start` 起由 `0:00` 开始计时。

### 选项

可在 `start` 时传入，也可在 `update` 时动态修改。

| 选项 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `variant` | `"regular" \| "mini"` | `"regular"` | 尺寸预设。 |
| `captionMode` | `"auto" \| "original" \| "bilingual"` | `"auto"` | `auto`：优先译文，无译文显示原文；`original`：优先原文；`bilingual`：原文加下一行译文。 |
| `maxVisibleItems` | `number` | `5` | 渲染最近多少条 `items`。 |
| `placeholder` | `string` | `"Listening..."` | 没有内容时显示的文字。 |
| `showIcon` | `boolean` | `true` | 顶部图标。 |
| `iconName` | `string` | 应用图标 | iOS：应用 bundle / asset catalog 中的图片名；Android：drawable 或 mipmap 资源名。 |
| `showDuration` | `boolean` | `true` | 顶部时长。 |
| `appearance.backgroundColor` | 颜色字符串 | `#121212` | 支持任意 React Native 颜色字符串。 |
| `appearance.textColor` | 颜色字符串 | `#FFFFFF` | 字幕颜色。 |
| `appearance.durationColor` | 颜色字符串 | 白色 62% | 时长文字（及 Android 关闭图标）颜色。 |
| `appearance.fontSize` | `number` | `19` / `15`（mini） | 字幕字号。 |
| `appearance.cornerRadius` | `number` | 平台预设 | 圆角。 |
| `showCloseButton` | `boolean` | `true` | 仅 Android。 |
| `draggable` | `boolean` | `true` | 仅 Android，按住顶部栏拖动。 |
| `position` | `{ x, y }`（dp） | `{ x: 16, y: 120 }` | 仅 Android，初始左上角位置。 |
| `iosAudioSession` | `"playAndRecord" \| "playback" \| "none"` | `"playAndRecord"` | 仅 iOS，见下。 |

## 平台注意事项

### iOS

- 画中画窗口的最终尺寸由系统决定，`variant` 只提供期望尺寸与宽高比提示。
- 画中画内容不可交互，点击由系统处理，因此没有自定义关闭按钮；用户通过系统控件关闭时会触发 `stop` 且 `userInitiated: true`。
- 画中画只能在应用处于前台、且音频会话已激活且非 ambient 时启动。调用 `start` 时若会话类别仍是 `ambient` / `soloAmbient`，模块会将其切换为 `playAndRecord`（或按 `iosAudioSession` 切为 `playback`）并带上 `mixWithOthers`；若应用已自行配置（例如录音库），则只做激活、不改类别。传 `iosAudioSession: "none"` 可完全不干预。
- 视频是放在“视频通话”型画中画窗口里播放的，这样才能在上面叠加自定义字幕；代价是没有系统的播放 / 暂停 / 快进按钮，需要由你的应用控制播放。
- 刚启动或刚回到前台时启动可能需要一点时间，模块会重试约 1.6 秒，之后触发 `error`。

### Android

- “显示在其他应用上层”权限必须由用户在系统设置中授予，没有应用内弹窗。
- 视频使用系统 `MediaPlayer` 播放，格式支持取决于设备（mp4 / H.264、HLS 普遍可用，不支持 DRM 和 DASH）。
- 关闭按钮只移除悬浮窗并触发 `stop`（`userInitiated: true`），是否同时停止转录由你的应用决定。
- JS 在后台被挂起时，原生链路可直接更新悬浮窗：

  ```kotlin
  import expo.modules.pipcaptions.PipCaptionsModule

  PipCaptionsModule.updateFromNative(
    mapOf(
      "durationMs" to elapsedMs,
      "items" to listOf(mapOf("key" to "1", "text" to "Hello", "translatedText" to "你好")),
    )
  )
  ```

  字段与 `updateFloatingCaptionAsync` 相同（颜色为 ARGB 整数），可在任意线程调用；在 JS 侧 `start` 之前调用会被忽略。

## 本库不做的事

语音识别、翻译、录音以及字幕文件解析（SRT / VTT）均不在范围内，模块只渲染你传入的快照；给视频配字幕时，请按当前进度用 `updateFloatingCaptionAsync` 推送对应的字幕。模块不会存储或上传任何字幕内容。

## 环境要求

- Expo SDK 53 及以上（基于 SDK 55 / React Native 0.83 开发）
- iOS 15.1+，Android 7.0+（API 24）

## License

MIT
