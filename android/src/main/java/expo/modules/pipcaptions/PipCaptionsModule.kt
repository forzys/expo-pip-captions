package expo.modules.pipcaptions

import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.SurfaceTexture
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.lang.ref.WeakReference

class PipCaptionsModule : Module() {
  private val context: Context
    get() = appContext.reactContext ?: throw Exceptions.ReactContextLost()

  private val windowManager: WindowManager
    get() = context.getSystemService(WindowManager::class.java)

  private val mainHandler = Handler(Looper.getMainLooper())
  private var overlayView: LinearLayout? = null
  private var overlayBackground: GradientDrawable? = null
  private var headerRow: LinearLayout? = null
  private var transcriptScrollView: ScrollView? = null
  private var transcriptTextView: TextView? = null
  private var iconImageView: ImageView? = null
  private var durationTextView: TextView? = null
  private var closeButton: ImageView? = null
  private var closeIcon: CloseIconDrawable? = null
  private var windowParams: WindowManager.LayoutParams? = null
  private var loadedIconName: String? = null
  private var active = false
  private var snapshot: Map<String, Any?> = emptyMap()
  private var durationBaseMs = 0L
  private var durationAnchorElapsedMs = 0L
  private var durationPaused = false

  private var videoContainer: AspectFrameLayout? = null
  private var videoTextureView: TextureView? = null
  private var videoSurface: Surface? = null
  private var mediaPlayer: MediaPlayer? = null
  private var loadedVideoUri: String? = null
  private var videoPrepared = false
  private var videoEnded = false
  private var videoWidth = 0
  private var videoHeight = 0
  private var pendingVideoSeekMs: Long? = null

  init {
    activeModule = WeakReference(this)
  }

  private val durationTicker = object : Runnable {
    override fun run() {
      if (!active || overlayView == null) {
        return
      }
      renderDuration()
      mainHandler.postDelayed(this, DURATION_TICK_INTERVAL_MS)
    }
  }

  companion object {
    private const val STATE_CHANGE_EVENT = "onStateChange"
    private const val DURATION_TICK_INTERVAL_MS = 1000L
    private const val REGULAR_TRANSCRIPT_HEIGHT_DP = 150
    private const val MINI_TRANSCRIPT_HEIGHT_DP = 64
    private const val DEFAULT_MAX_VISIBLE_ITEMS = 5
    private val DEFAULT_BACKGROUND_COLOR = Color.rgb(18, 18, 18)
    private val DEFAULT_DURATION_COLOR = Color.argb(160, 255, 255, 255)
    private var activeModule: WeakReference<PipCaptionsModule>? = null

    /**
     * Pushes a snapshot from native code, e.g. from a transcription pipeline that keeps
     * running while JS is suspended in the background. Takes the same keys as the JS
     * `updateFloatingCaptionAsync`, with colors as ARGB ints. Safe to call from any thread;
     * ignored until the surface has been started from JS.
     */
    @JvmStatic
    fun updateFromNative(snapshot: Map<String, Any?>) {
      val module = activeModule?.get() ?: return
      module.mainHandler.post {
        module.update(snapshot)
      }
    }
  }

  // The overlay is a plain View hierarchy, so every function runs on the main thread.
  override fun definition() = ModuleDefinition {
    Name("ExpoPipCaptions")

    Events(STATE_CHANGE_EVENT)

    AsyncFunction("getStatusAsync") {
      return@AsyncFunction status()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("requestPermissionAsync") {
      if (!hasOverlayPermission()) {
        val intent = Intent(
          Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
          Uri.parse("package:${context.packageName}")
        ).apply {
          addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
      }
      return@AsyncFunction status(if (hasOverlayPermission()) null else "Overlay permission is required")
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("startAsync") { options: Map<String, Any?> ->
      snapshot = options.filterValues { it != null }
      if (!hasOverlayPermission()) {
        return@AsyncFunction status("Overlay permission is required")
      }

      val wasActive = active
      active = true
      try {
        render(resetDuration = true)
      } catch (error: Exception) {
        val message = error.message ?: "Unable to show the overlay window"
        dismiss()
        sendStateChange("error", mapOf("message" to message))
        return@AsyncFunction status(message)
      }
      if (!wasActive) {
        sendStateChange("start")
      }
      return@AsyncFunction status()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("updateAsync") { incoming: Map<String, Any?> ->
      update(incoming)
      return@AsyncFunction status(if (hasOverlayPermission()) null else "Overlay permission is required")
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("pauseAsync") { paused: Boolean ->
      update(mapOf("isPaused" to paused))
      return@AsyncFunction status()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("seekVideoAsync") { positionMs: Double ->
      seekVideo(positionMs.toLong().coerceAtLeast(0L))
      return@AsyncFunction status()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("stopAsync") {
      close(userInitiated = false)
      return@AsyncFunction status()
    }.runOnQueue(Queues.MAIN)

    OnDestroy {
      mainHandler.post {
        dismiss()
      }
    }
  }

  private fun hasOverlayPermission(): Boolean {
    return Settings.canDrawOverlays(context)
  }

  private fun status(reason: String? = null): Map<String, Any?> {
    return mapOf(
      "supported" to true,
      "active" to active,
      "permissionGranted" to hasOverlayPermission(),
      "platform" to "android",
      "reason" to reason,
      "video" to videoStatus()
    ).filterValues { it != null }
  }

  private fun videoStatus(): Map<String, Any?>? {
    val player = mediaPlayer?.takeIf { videoPrepared } ?: return null
    return runCatching {
      mapOf(
        "playing" to player.isPlaying,
        "positionMs" to player.currentPosition.coerceAtLeast(0),
        "durationMs" to player.duration.takeIf { it >= 0 }
      ).filterValues { it != null }
    }.getOrNull()
  }

  private fun sendStateChange(type: String, extra: Map<String, Any?> = emptyMap()) {
    runCatching {
      sendEvent(STATE_CHANGE_EVENT, extra + mapOf("type" to type, "status" to status()))
    }
  }

  // Nested maps (`video`, `appearance`) are merged one level deep, so a partial update
  // such as `video: { paused: true }` keeps the other keys.
  private fun update(incoming: Map<String, Any?>) {
    val merged = snapshot.toMutableMap()
    for ((key, value) in incoming) {
      val current = merged[key]
      when {
        value == null -> merged.remove(key)
        value is Map<*, *> && current is Map<*, *> ->
          merged[key] = current + value.filterValues { it != null }
        else -> merged[key] = value
      }
    }
    snapshot = merged
    if (active && hasOverlayPermission()) {
      runCatching {
        render(resetDuration = false)
      }
    }
  }

  private fun close(userInitiated: Boolean) {
    val wasActive = active
    dismiss()
    if (wasActive) {
      sendStateChange("stop", mapOf("userInitiated" to userInitiated))
    }
  }

  private fun dismiss() {
    active = false
    snapshot = emptyMap()
    stopDurationTicker()
    removeOverlay()
  }

  private fun render(resetDuration: Boolean) {
    syncDuration(resetDuration)
    ensureOverlay()
    applyStyle()
    applyVideo()
    applyOverlayLayout()
    renderDuration()

    val lines = captionLines()
    // Next to a video the placeholder only shows when the app asked for one.
    val placeholder = snapshot.string("placeholder") ?: if (hasVideo()) null else "Listening..."
    val text = if (lines.isEmpty()) placeholder else lines.joinToString("\n")
    transcriptTextView?.text = text
    transcriptScrollView?.visibility = if (text == null) View.GONE else View.VISIBLE
    // Keeps the newest caption visible once the text outgrows the viewport.
    transcriptScrollView?.post {
      transcriptScrollView?.fullScroll(View.FOCUS_DOWN)
    }
  }

  private fun ensureOverlay() {
    if (overlayView != null) {
      return
    }

    val background = GradientDrawable().apply {
      setStroke(1, Color.argb(80, 255, 255, 255))
    }
    val root = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      this.background = background
      elevation = dp(8).toFloat()
    }

    val header = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
    }

    val icon = ImageView(context).apply {
      scaleType = ImageView.ScaleType.CENTER_CROP
    }

    val duration = TextView(context).apply {
      maxLines = 1
      gravity = Gravity.END
    }

    val closeDrawable = CloseIconDrawable(dp(2).toFloat())
    val closeView = ImageView(context).apply {
      setImageDrawable(closeDrawable)
      scaleType = ImageView.ScaleType.FIT_XY
      isClickable = true
      isFocusable = true
      contentDescription = "Close"
      this.background = GradientDrawable().apply {
        setColor(Color.argb(24, 255, 255, 255))
        cornerRadius = dp(12).toFloat()
      }
      setOnClickListener {
        close(userInitiated = true)
      }
    }

    val transcript = TextView(context).apply {
      setTextColor(Color.WHITE)
    }
    val scroll = ScrollView(context).apply {
      isVerticalScrollBarEnabled = false
      overScrollMode = View.OVER_SCROLL_NEVER
      isFillViewport = true
      addView(
        transcript,
        FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT,
          ViewGroup.LayoutParams.WRAP_CONTENT
        )
      )
    }

    header.addView(icon, LinearLayout.LayoutParams(dp(24), dp(24)))
    header.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
    header.addView(duration)
    header.addView(closeView, LinearLayout.LayoutParams(dp(28), dp(28)))

    val texture = TextureView(context).apply {
      surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
          val surface = Surface(surfaceTexture)
          videoSurface = surface
          runCatching { mediaPlayer?.setSurface(surface) }
          updateVideoTransform()
        }

        override fun onSurfaceTextureSizeChanged(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
          updateVideoTransform()
        }

        override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
          runCatching { mediaPlayer?.setSurface(null) }
          videoSurface?.release()
          videoSurface = null
          return true
        }

        override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) = Unit
      }
    }
    val videoRadius = dp(8).toFloat()
    val video = AspectFrameLayout(context).apply {
      setBackgroundColor(Color.BLACK)
      visibility = View.GONE
      outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
          outline.setRoundRect(0, 0, view.width, view.height, videoRadius)
        }
      }
      clipToOutline = true
      addView(
        texture,
        FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT,
          ViewGroup.LayoutParams.MATCH_PARENT
        )
      )
    }

    root.addView(header)
    root.addView(
      video,
      LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
      ).apply {
        topMargin = dp(8)
      }
    )
    root.addView(
      scroll,
      LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        dp(REGULAR_TRANSCRIPT_HEIGHT_DP)
      )
    )

    val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
      @Suppress("DEPRECATION")
      WindowManager.LayoutParams.TYPE_PHONE
    }

    val position = snapshot.nested("position")
    val params = WindowManager.LayoutParams(
      overlayWidth(),
      WindowManager.LayoutParams.WRAP_CONTENT,
      type,
      // TextureView only renders in a hardware accelerated window.
      WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
      PixelFormat.TRANSLUCENT
    ).apply {
      gravity = Gravity.TOP or Gravity.START
      x = dp(position.number("x")?.toInt() ?: 16)
      y = dp(position.number("y")?.toInt() ?: 120)
    }

    // Only the header is a drag handle, so dragging never fights the caption ScrollView.
    makeDraggable(header, root)
    windowManager.addView(root, params)

    overlayView = root
    overlayBackground = background
    headerRow = header
    iconImageView = icon
    durationTextView = duration
    closeButton = closeView
    closeIcon = closeDrawable
    transcriptTextView = transcript
    transcriptScrollView = scroll
    videoContainer = video
    videoTextureView = texture
    windowParams = params
    loadedIconName = null
    icon.setImageDrawable(loadIcon(null))
  }

  private fun applyStyle() {
    val isMini = snapshot["variant"] == "mini"
    val appearance = snapshot.nested("appearance")
    val durationColor = appearance.color("durationColor") ?: DEFAULT_DURATION_COLOR
    val showIcon = snapshot.bool("showIcon", true)
    val showDuration = snapshot.bool("showDuration", true)
    val showCloseButton = snapshot.bool("showCloseButton", true)

    overlayBackground?.apply {
      setColor(appearance.color("backgroundColor") ?: DEFAULT_BACKGROUND_COLOR)
      cornerRadius = dp(appearance.number("cornerRadius")?.toInt()?.coerceAtLeast(0) ?: 16).toFloat()
    }
    overlayView?.setPadding(
      if (isMini) dp(12) else dp(20),
      if (isMini) dp(10) else dp(16),
      if (isMini) dp(8) else dp(10),
      if (isMini) dp(10) else dp(16)
    )

    val iconName = snapshot.string("iconName")
    if (iconName != loadedIconName) {
      loadedIconName = iconName
      iconImageView?.setImageDrawable(loadIcon(iconName))
    }
    iconImageView?.visibility = if (showIcon) View.VISIBLE else View.GONE
    iconImageView?.layoutParams = iconImageView?.layoutParams?.apply {
      width = if (isMini) dp(20) else dp(24)
      height = if (isMini) dp(20) else dp(24)
    }

    durationTextView?.visibility = if (showDuration) View.VISIBLE else View.GONE
    durationTextView?.setTextColor(durationColor)
    durationTextView?.textSize = if (isMini) 11f else 12f

    closeIcon?.setColor(durationColor)
    closeButton?.visibility = if (showCloseButton) View.VISIBLE else View.GONE
    closeButton?.layoutParams = closeButton?.layoutParams?.apply {
      width = if (isMini) dp(24) else dp(28)
      height = if (isMini) dp(24) else dp(28)
      if (this is LinearLayout.LayoutParams) {
        marginStart = if (isMini) dp(8) else dp(10)
      }
    }
    val closePadding = if (isMini) dp(7) else dp(8)
    closeButton?.setPadding(closePadding, closePadding, closePadding, closePadding)

    // With nothing in it the header still has to stay as a drag handle.
    val headerEmpty = !showIcon && !showDuration && !showCloseButton
    headerRow?.minimumHeight = if (headerEmpty) dp(16) else 0

    transcriptTextView?.setTextColor(appearance.color("textColor") ?: Color.WHITE)
    transcriptTextView?.textSize = appearance.number("fontSize")?.toFloat()?.takeIf { it > 0f }
      ?: if (isMini) 15f else 19f
    transcriptTextView?.setPadding(0, if (isMini) dp(6) else dp(10), 0, 0)
    transcriptScrollView?.layoutParams = transcriptScrollView?.layoutParams?.apply {
      // The video already takes most of the height, so captions get the compact viewport.
      height = dp(if (isMini || hasVideo()) MINI_TRANSCRIPT_HEIGHT_DP else REGULAR_TRANSCRIPT_HEIGHT_DP)
    }
    transcriptScrollView?.requestLayout()
  }

  private fun hasVideo(): Boolean {
    return snapshot.nested("video").string("uri") != null
  }

  private fun applyVideo() {
    val container = videoContainer ?: return
    val video = snapshot.nested("video")
    val uri = video.string("uri")
    if (uri == null) {
      releaseVideo()
      container.visibility = View.GONE
      return
    }

    container.visibility = View.VISIBLE
    if (uri != loadedVideoUri) {
      releaseVideo()
      loadVideo(uri, video)
    }

    val player = mediaPlayer ?: return
    val volume = if (video.bool("muted", false)) {
      0f
    } else {
      (video.number("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
    }
    runCatching {
      player.setVolume(volume, volume)
      player.isLooping = video.bool("loop", false)
      if (videoPrepared) {
        val paused = video.bool("paused", false)
        if (paused && player.isPlaying) {
          player.pause()
        } else if (!paused && !player.isPlaying && !videoEnded) {
          // start() after completion would replay from the beginning on every update.
          player.start()
        }
      }
    }
    updateVideoTransform()
  }

  private fun loadVideo(uri: String, video: Map<*, *>) {
    loadedVideoUri = uri
    pendingVideoSeekMs = video.number("positionMs")?.toLong()?.takeIf { it > 0 }
    val headers = (video["headers"] as? Map<*, *>)
      ?.mapNotNull { (key, value) -> if (key is String && value is String) key to value else null }
      ?.toMap()
      ?: emptyMap()

    val player = MediaPlayer()
    mediaPlayer = player
    try {
      player.setAudioAttributes(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
          .build()
      )
      player.setDataSource(context, Uri.parse(uri), headers)
      player.setOnPreparedListener {
        if (it === mediaPlayer) {
          videoPrepared = true
          pendingVideoSeekMs?.let { positionMs -> runCatching { seekPlayer(it, positionMs) } }
          pendingVideoSeekMs = null
          sendStateChange("videoReady")
          applyVideo()
        }
      }
      player.setOnVideoSizeChangedListener { changed, width, height ->
        if (changed === mediaPlayer && width > 0 && height > 0) {
          videoWidth = width
          videoHeight = height
          videoContainer?.aspectRatio = (width.toFloat() / height).coerceIn(0.75f, 2.4f)
          updateVideoTransform()
        }
      }
      player.setOnCompletionListener {
        if (it === mediaPlayer && !it.isLooping) {
          videoEnded = true
          sendStateChange("videoEnd")
        }
      }
      player.setOnErrorListener { failed, what, extra ->
        if (failed === mediaPlayer) {
          videoPrepared = false
          sendStateChange("videoError", mapOf("message" to "MediaPlayer error $what ($extra)"))
        }
        true
      }
      videoSurface?.let { player.setSurface(it) }
      player.prepareAsync()
    } catch (error: Exception) {
      sendStateChange("videoError", mapOf("message" to (error.message ?: "Unable to play the video")))
    }
  }

  private fun seekVideo(positionMs: Long) {
    val player = mediaPlayer ?: return
    videoEnded = false
    if (!videoPrepared) {
      pendingVideoSeekMs = positionMs
      return
    }
    runCatching { seekPlayer(player, positionMs) }
    applyVideo()
  }

  private fun seekPlayer(player: MediaPlayer, positionMs: Long) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      player.seekTo(positionMs, MediaPlayer.SEEK_CLOSEST)
    } else {
      player.seekTo(positionMs.toInt())
    }
  }

  private fun releaseVideo() {
    mediaPlayer?.let { runCatching { it.release() } }
    mediaPlayer = null
    loadedVideoUri = null
    videoPrepared = false
    videoEnded = false
    videoWidth = 0
    videoHeight = 0
    pendingVideoSeekMs = null
  }

  // Scales the stretched TextureView content back to the video's own aspect ratio.
  private fun updateVideoTransform() {
    val view = videoTextureView ?: return
    val viewWidth = view.width.toFloat()
    val viewHeight = view.height.toFloat()
    if (viewWidth <= 0f || viewHeight <= 0f || videoWidth <= 0 || videoHeight <= 0) {
      return
    }

    val videoAspect = videoWidth.toFloat() / videoHeight
    val viewAspect = viewWidth / viewHeight
    val cover = snapshot.nested("video").string("resizeMode") == "cover"
    var scaleX = 1f
    var scaleY = 1f
    if ((videoAspect > viewAspect) != cover) {
      scaleY = viewAspect / videoAspect
    } else {
      scaleX = videoAspect / viewAspect
    }
    view.setTransform(Matrix().apply { setScale(scaleX, scaleY, viewWidth / 2f, viewHeight / 2f) })
  }

  private fun loadIcon(name: String?): Drawable? {
    if (name != null) {
      val resources = context.resources
      val id = sequenceOf("drawable", "mipmap")
        .map { resources.getIdentifier(name, it, context.packageName) }
        .firstOrNull { it != 0 }
      if (id != null) {
        runCatching { context.getDrawable(id) }.getOrNull()?.let { return it }
      }
    }
    return context.packageManager.getApplicationIcon(context.applicationInfo)
  }

  private fun usesStaticDurationLabel(): Boolean {
    return snapshot["durationMs"] !is Number && snapshot.string("durationLabel") != null
  }

  private fun syncDuration(reset: Boolean) {
    val now = SystemClock.elapsedRealtime()
    val incomingDuration = (snapshot.number("durationMs")?.toLong() ?: 0L).coerceAtLeast(0L)

    // JS may be suspended in the background and resume with a stale value, so the
    // native clock only ever moves forward within one session.
    durationBaseMs = if (reset) incomingDuration else maxOf(currentDurationMs(now), incomingDuration)
    durationAnchorElapsedMs = now
    durationPaused = snapshot.bool("isPaused", false)

    if (active && !durationPaused && !usesStaticDurationLabel() && snapshot.bool("showDuration", true)) {
      startDurationTicker()
    } else {
      stopDurationTicker()
    }
  }

  private fun currentDurationMs(now: Long = SystemClock.elapsedRealtime()): Long {
    val runningElapsed = if (active && !durationPaused) {
      (now - durationAnchorElapsedMs).coerceAtLeast(0L)
    } else {
      0L
    }
    return durationBaseMs + runningElapsed
  }

  private fun renderDuration() {
    val label = if (usesStaticDurationLabel()) snapshot.string("durationLabel") else null
    if (label != null) {
      durationTextView?.text = label
      return
    }

    val totalSeconds = currentDurationMs() / 1000L
    val hours = totalSeconds / 3600L
    val minutes = (totalSeconds % 3600L) / 60L
    val seconds = (totalSeconds % 60L).toString().padStart(2, '0')
    durationTextView?.text = if (hours > 0) {
      "$hours:${minutes.toString().padStart(2, '0')}:$seconds"
    } else {
      "$minutes:$seconds"
    }
  }

  private fun startDurationTicker() {
    mainHandler.removeCallbacks(durationTicker)
    mainHandler.postDelayed(durationTicker, DURATION_TICK_INTERVAL_MS)
  }

  private fun stopDurationTicker() {
    mainHandler.removeCallbacks(durationTicker)
  }

  private fun applyOverlayLayout() {
    val view = overlayView ?: return
    val params = windowParams ?: return
    val nextWidth = overlayWidth()
    if (params.width != nextWidth) {
      params.width = nextWidth
      val maxX = (context.resources.displayMetrics.widthPixels - nextWidth - dp(8)).coerceAtLeast(dp(8))
      params.x = params.x.coerceIn(dp(8), maxX)
      windowManager.updateViewLayout(view, params)
    }
  }

  private fun overlayWidth(): Int {
    val displayWidth = context.resources.displayMetrics.widthPixels
    return if (snapshot["variant"] == "mini") {
      (displayWidth * 0.54f)
        .toInt()
        .coerceAtLeast(dp(210))
        .coerceAtMost(displayWidth - dp(24))
    } else {
      displayWidth - dp(32)
    }
  }

  private fun captionLines(): List<String> {
    val items = snapshot["items"] as? List<*> ?: return emptyList()
    val maxItems = (snapshot.number("maxVisibleItems")?.toInt() ?: DEFAULT_MAX_VISIBLE_ITEMS).coerceAtLeast(1)
    val mode = snapshot.string("captionMode") ?: "auto"

    return items.takeLast(maxItems).mapNotNull { item ->
      val segment = item as? Map<*, *> ?: return@mapNotNull null
      val text = segment.string("text")
      val translated = segment.string("translatedText")
      val fallback = segment.string("displayText")

      when (mode) {
        "original" -> text ?: translated ?: fallback
        "bilingual" -> listOfNotNull(text, translated.takeIf { it != text })
          .joinToString("\n")
          .ifEmpty { null }
          ?: fallback
        else -> translated ?: text ?: fallback
      }
    }
  }

  private fun removeOverlay() {
    val view = overlayView ?: return
    releaseVideo()
    runCatching {
      windowManager.removeView(view)
    }
    videoSurface?.release()
    videoSurface = null
    videoContainer = null
    videoTextureView = null
    overlayView = null
    overlayBackground = null
    headerRow = null
    transcriptScrollView = null
    transcriptTextView = null
    iconImageView = null
    durationTextView = null
    closeButton = null
    closeIcon = null
    windowParams = null
    loadedIconName = null
  }

  private fun makeDraggable(handleView: View, windowView: View) {
    var startX = 0
    var startY = 0
    var touchStartX = 0f
    var touchStartY = 0f

    handleView.setOnTouchListener { _, event ->
      val params = windowParams ?: return@setOnTouchListener false
      if (!snapshot.bool("draggable", true)) {
        return@setOnTouchListener false
      }
      when (event.action) {
        MotionEvent.ACTION_DOWN -> {
          startX = params.x
          startY = params.y
          touchStartX = event.rawX
          touchStartY = event.rawY
          true
        }

        MotionEvent.ACTION_MOVE -> {
          val metrics = context.resources.displayMetrics
          val maxX = (metrics.widthPixels - windowView.width).coerceAtLeast(0)
          val maxY = (metrics.heightPixels - windowView.height).coerceAtLeast(0)
          params.x = (startX + (event.rawX - touchStartX).toInt()).coerceIn(0, maxX)
          params.y = (startY + (event.rawY - touchStartY).toInt()).coerceIn(0, maxY)
          windowManager.updateViewLayout(windowView, params)
          true
        }

        else -> false
      }
    }
  }

  private fun dp(value: Int): Int {
    return (value * context.resources.displayMetrics.density).toInt()
  }
}

private fun Map<*, *>.string(key: String): String? {
  return (this[key] as? String)?.trim()?.takeIf { it.isNotEmpty() }
}

private fun Map<*, *>.bool(key: String, default: Boolean): Boolean {
  return this[key] as? Boolean ?: default
}

private fun Map<*, *>.number(key: String): Double? {
  return (this[key] as? Number)?.toDouble()?.takeIf { it.isFinite() }
}

private fun Map<*, *>.nested(key: String): Map<*, *> {
  return this[key] as? Map<*, *> ?: emptyMap<String, Any?>()
}

// Colors arrive as ARGB integers produced by React Native's `processColor`.
private fun Map<*, *>.color(key: String): Int? {
  return (this[key] as? Number)?.toLong()?.toInt()
}

private class AspectFrameLayout(context: Context) : FrameLayout(context) {
  var aspectRatio = 16f / 9f
    set(value) {
      if (value > 0f && field != value) {
        field = value
        requestLayout()
      }
    }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val width = MeasureSpec.getSize(widthMeasureSpec)
    super.onMeasure(
      widthMeasureSpec,
      MeasureSpec.makeMeasureSpec((width / aspectRatio).toInt(), MeasureSpec.EXACTLY)
    )
  }
}

private class CloseIconDrawable(strokeWidth: Float) : Drawable() {
  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    this.strokeWidth = strokeWidth
  }

  fun setColor(color: Int) {
    if (paint.color != color) {
      paint.color = color
      invalidateSelf()
    }
  }

  override fun draw(canvas: Canvas) {
    val left = bounds.left.toFloat()
    val top = bounds.top.toFloat()
    val right = bounds.right.toFloat()
    val bottom = bounds.bottom.toFloat()
    canvas.drawLine(left, top, right, bottom, paint)
    canvas.drawLine(right, top, left, bottom, paint)
  }

  override fun setAlpha(alpha: Int) {
    paint.alpha = alpha
    invalidateSelf()
  }

  override fun setColorFilter(colorFilter: ColorFilter?) {
    paint.colorFilter = colorFilter
    invalidateSelf()
  }

  @Deprecated("Deprecated in Java")
  override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
