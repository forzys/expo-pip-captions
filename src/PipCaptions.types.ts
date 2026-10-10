export type FloatingCaptionSegment = {
    /** Stable identifier of the segment. */
    key: string
    /** Original (source language) text. */
    text: string
    /** Translated text. Preferred over `text` in the default caption mode. */
    translatedText?: string | null
    /** Last-resort fallback, used only when both `text` and `translatedText` are empty. */
    displayText?: string | null
}

export type FloatingCaptionVariant = "regular" | "mini"

/**
 * Which text of a segment is rendered.
 * - `auto`: `translatedText`, falling back to `text` (default)
 * - `original`: `text`, falling back to `translatedText`
 * - `bilingual`: `text` followed by `translatedText` on the next line
 */
export type FloatingCaptionMode = "auto" | "original" | "bilingual"

export type FloatingCaptionAppearance = {
    /** Any React Native color string, e.g. `#111111`, `rgba(0,0,0,0.8)`. */
    backgroundColor?: string
    /** Caption text color. */
    textColor?: string
    /** Color of the duration label (and of the Android close icon). */
    durationColor?: string
    /** Caption font size in points / sp. Defaults to 19 (`regular`) or 15 (`mini`). */
    fontSize?: number
    /** Corner radius in points / dp. */
    cornerRadius?: number
}

export type FloatingCaptionOptions = {
    /** Size preset. Defaults to `regular`. */
    variant?: FloatingCaptionVariant
    /** Defaults to `auto`. */
    captionMode?: FloatingCaptionMode
    /** How many of the latest `items` are rendered. Defaults to 5. */
    maxVisibleItems?: number
    /** Text shown while there is nothing to render. Defaults to `Listening...`. */
    placeholder?: string
    /** Show an icon in the header. Defaults to true. */
    showIcon?: boolean
    /**
     * Icon to show instead of the app icon: an image name in the app bundle / asset
     * catalog on iOS, a drawable or mipmap resource name on Android.
     */
    iconName?: string
    /** Show the duration label in the header. Defaults to true. */
    showDuration?: boolean
    appearance?: FloatingCaptionAppearance
    /** Android only. Show the close button in the header. Defaults to true. */
    showCloseButton?: boolean
    /** Android only. Allow dragging the overlay by its header. Defaults to true. */
    draggable?: boolean
    /** Android only. Initial top-left position in dp. Defaults to `{ x: 16, y: 120 }`. */
    position?: { x: number; y: number }
    /**
     * iOS only. Audio session category applied on start when the session is still
     * `ambient` / `soloAmbient`. Picture in Picture needs an active, non-ambient
     * session. Use `none` if the app manages the audio session itself.
     * Defaults to `playAndRecord`.
     */
    iosAudioSession?: "playAndRecord" | "playback" | "none"
}

export type FloatingCaptionSnapshot = FloatingCaptionOptions & {
    items: FloatingCaptionSegment[]
    /**
     * Elapsed time in milliseconds. When provided, the native side keeps the label
     * ticking on its own, so it stays correct while JS is suspended in the background.
     */
    durationMs?: number
    /** Preformatted label rendered as-is. Ignored when `durationMs` is provided. */
    durationLabel?: string
    /** Freezes the native duration ticker. */
    isPaused?: boolean
    /** Not rendered. Carried for host apps that bridge snapshots natively. */
    isStopping?: boolean
    /** Not rendered. */
    recordingId?: string | null
    /** Not rendered. */
    sourceLanguage?: string | null
    /** Not rendered. */
    targetLanguage?: string | null
}

export type FloatingCaptionStartOptions = FloatingCaptionSnapshot & {
    /** Not rendered. */
    title?: string
}

export type FloatingCaptionStatus = {
    supported: boolean
    active: boolean
    permissionGranted: boolean
    platform: "ios" | "android" | "web" | "unknown"
    reason?: string
}

export type FloatingCaptionEvent = {
    type: "start" | "stop" | "error"
    /**
     * `stop` only: true when the user dismissed the surface (Android close button,
     * iOS system PiP controls) instead of the app calling `stopFloatingCaptionAsync`.
     */
    userInitiated?: boolean
    /** `error` only. */
    message?: string
    status: FloatingCaptionStatus
}

export type FloatingCaptionSubscription = {
    remove(): void
}

export type PipCaptionsNativeModule = {
    getStatusAsync(): Promise<FloatingCaptionStatus>
    requestPermissionAsync(): Promise<FloatingCaptionStatus>
    startAsync(options: Record<string, unknown>): Promise<FloatingCaptionStatus>
    updateAsync(snapshot: Record<string, unknown>): Promise<FloatingCaptionStatus>
    pauseAsync(paused: boolean): Promise<FloatingCaptionStatus>
    stopAsync(): Promise<FloatingCaptionStatus>
    addListener(
        eventName: "onStateChange",
        listener: (event: FloatingCaptionEvent) => void,
    ): FloatingCaptionSubscription
}
