import { processColor } from "react-native"
import PipCaptionsModule from "./PipCaptionsModule"
import type {
    FloatingCaptionAppearance,
    FloatingCaptionEvent,
    FloatingDanmakuItem,
    FloatingCaptionStartOptions,
    FloatingCaptionSubscription,
    FloatingCaptionUpdate,
} from "./PipCaptions.types"

export type * from "./PipCaptions.types"

const COLOR_KEYS = ["backgroundColor", "textColor", "durationColor"] as const

// Colors cross the bridge as ARGB integers so both platforms accept any RN color string.
const toNativeAppearance = (appearance: FloatingCaptionAppearance) => {
    const result: Record<string, unknown> = { ...appearance }
    for (const key of COLOR_KEYS) {
        const color = appearance[key] == null ? null : processColor(appearance[key])
        if (typeof color === "number") {
            result[key] = color
        } else {
            delete result[key]
        }
    }
    return result
}

const toNativeSnapshot = (snapshot: FloatingCaptionUpdate & { title?: string }) => {
    const { appearance, video, ...rest } = snapshot
    const result: Record<string, unknown> = rest
    if (appearance) {
        result.appearance = toNativeAppearance(appearance)
    }
    if (video !== undefined) {
        // null does not survive the bridge on every platform; false means "no video" natively.
        result.video = video ?? false
    }
    return result
}

export const getFloatingCaptionStatusAsync = () => PipCaptionsModule.getStatusAsync()

/**
 * Android: opens the system overlay permission screen when the permission is missing.
 * The returned status reflects the state before the user comes back, so re-check with
 * `getFloatingCaptionStatusAsync()` when the app returns to the foreground.
 * iOS: resolves with the current status, Picture in Picture needs no permission.
 */
export const requestFloatingCaptionPermissionAsync = () => PipCaptionsModule.requestPermissionAsync()

/**
 * Shows the floating caption surface. On iOS the returned status usually still has
 * `active: false`, because Picture in Picture starts asynchronously; listen for the
 * `start` / `error` events to know the outcome.
 */
export const startFloatingCaptionAsync = (options: FloatingCaptionStartOptions) =>
    PipCaptionsModule.startAsync(toNativeSnapshot(options))

/**
 * Merges `snapshot` into the current one, so options passed to
 * `startFloatingCaptionAsync` stay in effect unless overridden here. Also how the
 * video is controlled: `{ video: { paused: true } }`, `{ video: { uri } }`, `{ video: null }`.
 */
export const updateFloatingCaptionAsync = (snapshot: FloatingCaptionUpdate) =>
    PipCaptionsModule.updateAsync(toNativeSnapshot(snapshot))

export const pauseFloatingCaptionAsync = (paused: boolean) => PipCaptionsModule.pauseAsync(paused)

/** Seeks the video playing in the floating window. No-op when there is none. */
export const seekFloatingVideoAsync = (positionMs: number) => PipCaptionsModule.seekVideoAsync(positionMs)

/**
 * Sends user comments (danmaku) across the video. Each one is shown once; they are separate
 * from the subtitles in `items`. Needs a video in the floating window.
 */
export const sendFloatingDanmakuAsync = (
    danmaku: string | FloatingDanmakuItem | (string | FloatingDanmakuItem)[],
) => {
    const items = (Array.isArray(danmaku) ? danmaku : [danmaku]).map((entry) => {
        const { text, color } = typeof entry === "string" ? { text: entry, color: undefined } : entry
        const nativeColor = color == null ? null : processColor(color)
        return typeof nativeColor === "number" ? { text, color: nativeColor } : { text }
    })
    return PipCaptionsModule.sendDanmakuAsync(items)
}

export const stopFloatingCaptionAsync = () => PipCaptionsModule.stopAsync()

export const addFloatingCaptionListener = (
    listener: (event: FloatingCaptionEvent) => void,
): FloatingCaptionSubscription => PipCaptionsModule.addListener("onStateChange", listener)

const PipCaptions = {
    getStatusAsync: getFloatingCaptionStatusAsync,
    requestPermissionAsync: requestFloatingCaptionPermissionAsync,
    startAsync: startFloatingCaptionAsync,
    updateAsync: updateFloatingCaptionAsync,
    pauseAsync: pauseFloatingCaptionAsync,
    seekVideoAsync: seekFloatingVideoAsync,
    sendDanmakuAsync: sendFloatingDanmakuAsync,
    stopAsync: stopFloatingCaptionAsync,
    addListener: addFloatingCaptionListener,
}

export default PipCaptions
