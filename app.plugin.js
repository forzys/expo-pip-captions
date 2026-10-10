const { withInfoPlist, createRunOncePlugin } = require("expo/config-plugins")
const pkg = require("./package.json")

/**
 * iOS Picture in Picture only keeps running while the app is allowed to stay
 * alive in the background, so the plugin adds the `audio` background mode
 * unless `enableBackgroundAudio` is set to false.
 *
 * Android needs no config: SYSTEM_ALERT_WINDOW is declared in the library
 * manifest and merged automatically.
 */
const withPipCaptions = (config, props) => {
    const { enableBackgroundAudio = true } = props ?? {}

    if (!enableBackgroundAudio) {
        return config
    }

    return withInfoPlist(config, (cfg) => {
        const modes = new Set(cfg.modResults.UIBackgroundModes ?? [])
        modes.add("audio")
        cfg.modResults.UIBackgroundModes = Array.from(modes)
        return cfg
    })
}

module.exports = createRunOncePlugin(withPipCaptions, pkg.name, pkg.version)
