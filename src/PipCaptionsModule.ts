import { requireOptionalNativeModule } from "expo"
import { Platform } from "react-native"
import type { FloatingCaptionStatus, PipCaptionsNativeModule } from "./PipCaptions.types"

const NativePipCaptions = requireOptionalNativeModule<PipCaptionsNativeModule>("ExpoPipCaptions")

const getFallbackStatus = (reason = "Native module is unavailable"): FloatingCaptionStatus => ({
    supported: false,
    active: false,
    permissionGranted: false,
    platform:
        Platform.OS === "ios" || Platform.OS === "android" || Platform.OS === "web"
            ? Platform.OS
            : "unknown",
    reason,
})

const createFallbackModule = (): PipCaptionsNativeModule => ({
    getStatusAsync: async () => getFallbackStatus(),
    requestPermissionAsync: async () => getFallbackStatus(),
    startAsync: async () => getFallbackStatus(),
    updateAsync: async () => getFallbackStatus(),
    pauseAsync: async () => getFallbackStatus(),
    seekVideoAsync: async () => getFallbackStatus(),
    sendDanmakuAsync: async () => getFallbackStatus(),
    stopAsync: async () => getFallbackStatus(),
    addListener: () => ({ remove: () => {} }),
})

export default NativePipCaptions ?? createFallbackModule()
