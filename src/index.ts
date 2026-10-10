import { processColor } from "react-native"
import PipCaptionsModule from "./PipCaptionsModule"
import type {
    FloatingCaptionAppearance,
    FloatingCaptionEvent,
    FloatingCaptionSnapshot,
    FloatingCaptionStartOptions,
    FloatingCaptionSubscription,
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

const toNativeSnapshot = (snapshot: Partial<FloatingCaptionStartOptions>) => {
    const { appearance, ...rest } = snapshot
    return appearance ? { ...rest, appearance: toNativeAppearance(appearance) } : rest
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
 * `startFloatingCaptionAsync` stay in effect unless overridden here.
 */
export const updateFloatingCaptionAsync = (snapshot: Partial<FloatingCaptionSnapshot>) =>
    PipCaptionsModule.updateAsync(toNativeSnapshot(snapshot))

export const pauseFloatingCaptionAsync = (paused: boolean) => PipCaptionsModule.pauseAsync(paused)

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
    stopAsync: stopFloatingCaptionAsync,
    addListener: addFloatingCaptionListener,
}

export default PipCaptions
