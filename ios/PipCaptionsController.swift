import AVFoundation
import AVKit
import UIKit

private struct PipCaptionsLayoutMetrics {
  var sourceWidth: CGFloat
  var sourceHeight: CGFloat
  var preferredSize: CGSize
  let horizontalInset: CGFloat
  let topInset: CGFloat
  let bottomInset: CGFloat
  let headerSpacing: CGFloat
  let iconSize: CGFloat
  let statusFontSize: CGFloat
  var captionFontSize: CGFloat
  let captionScrollMaxLines: Int
  var cornerRadius: CGFloat

  static func resolve(
    snapshot: [String: Any],
    containerWidth: CGFloat,
    videoAspect: CGFloat? = nil
  ) -> PipCaptionsLayoutMetrics {
    let safeContainerWidth = max(containerWidth, 260)
    var metrics: PipCaptionsLayoutMetrics

    if snapshot.string("variant") == "mini" {
      let width = min(max(safeContainerWidth * 0.54, 210), safeContainerWidth - 24)
      metrics = PipCaptionsLayoutMetrics(
        sourceWidth: width,
        sourceHeight: 148,
        preferredSize: CGSize(width: min(max(width, 220), 260), height: 156),
        horizontalInset: 14,
        topInset: 12,
        bottomInset: 10,
        headerSpacing: 6,
        iconSize: 20,
        statusFontSize: 13,
        captionFontSize: 15,
        captionScrollMaxLines: 6,
        cornerRadius: 18
      )
    } else {
      let width = min(max(safeContainerWidth - 8, 340), 620)
      let height = min(max(width * 9 / 16, 204), 292)
      metrics = PipCaptionsLayoutMetrics(
        sourceWidth: width,
        sourceHeight: height,
        preferredSize: CGSize(width: width, height: height),
        horizontalInset: 18,
        topInset: 16,
        bottomInset: 18,
        headerSpacing: 10,
        iconSize: 24,
        statusFontSize: 15,
        captionFontSize: 19,
        captionScrollMaxLines: 8,
        cornerRadius: 20
      )
    }

    let appearance = snapshot.dictionary("appearance")
    if let fontSize = appearance.double("fontSize"), fontSize > 0 {
      metrics.captionFontSize = CGFloat(fontSize)
    }
    if let cornerRadius = appearance.double("cornerRadius"), cornerRadius >= 0 {
      metrics.cornerRadius = CGFloat(cornerRadius)
    }

    // With a video the window follows the video's aspect ratio instead of the preset.
    if let videoAspect {
      let aspect = min(max(videoAspect, 0.5), 2.4)
      metrics.preferredSize = CGSize(
        width: metrics.preferredSize.width,
        height: metrics.preferredSize.width / aspect
      )
      metrics.sourceHeight = min(metrics.sourceWidth / aspect, 400)
      metrics.sourceWidth = metrics.sourceHeight * aspect
    }
    return metrics
  }
}

/// Owns the Picture in Picture session. Every method must be called on the main thread.
final class PipCaptionsController: NSObject, AVPictureInPictureControllerDelegate {
  var onEvent: (([String: Any]) -> Void)?

  private var pictureInPictureController: AVPictureInPictureController?
  private var sourceView: UIView?
  private var sourceWidthConstraint: NSLayoutConstraint?
  private var sourceHeightConstraint: NSLayoutConstraint?
  private var captionViewController: PipCaptionsViewController?
  private var snapshot: [String: Any] = [:]
  private var active = false
  private var starting = false
  private var lastReason: String?
  // Bumped on every start/stop so a pending start retry from an older session is dropped.
  private var startGeneration = 0
  private var stopRequestedByApp = false

  private var durationBaseMs: Double = 0
  private var durationAnchor: CFTimeInterval = 0
  private var durationRunning = false
  private var durationTimer: Timer?
  private var sessionLive = false

  private var player: AVPlayer?
  private var loadedVideoURI: String?
  private var videoAspect: CGFloat?
  private var videoObservations: [NSKeyValueObservation] = []
  private var videoEndObserver: NSObjectProtocol?

  func getStatus(reason: String? = nil) -> [String: Any] {
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    let isActive = active || pictureInPictureController?.isPictureInPictureActive == true
    var result: [String: Any] = [
      "supported": supported,
      "active": isActive,
      "permissionGranted": true,
      "platform": "ios"
    ]

    if let player {
      var video: [String: Any] = [
        "playing": player.rate != 0,
        "positionMs": max(0, player.currentTime().seconds.finiteOrZero * 1000)
      ]
      if let duration = player.currentItem?.duration.seconds, duration.isFinite {
        video["durationMs"] = duration * 1000
      }
      result["video"] = video
    }

    if let reason = reason ?? lastReason {
      result["reason"] = reason
    } else if !supported {
      result["reason"] = "Picture in Picture is not supported on this device"
    } else if starting {
      result["reason"] = "Picture in Picture is starting"
    }

    return result
  }

  func requestPermission() -> [String: Any] {
    getStatus(reason: "iOS does not expose a floating-window permission")
  }

  func start(options: [String: Any]) -> [String: Any] {
    snapshot = Self.sanitized(options)
    lastReason = nil
    stopRequestedByApp = false
    startGeneration += 1

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      fail("Picture in Picture is not supported on this device")
      return getStatus()
    }

    sessionLive = true
    syncDuration(reset: true)
    startPictureInPicture()
    return getStatus()
  }

  func update(snapshot incoming: [String: Any]) -> [String: Any] {
    merge(incoming)
    syncDuration(reset: false)
    applyVideo()
    applySourceLayout()
    render()
    return getStatus()
  }

  func pause(paused: Bool) -> [String: Any] {
    snapshot["isPaused"] = paused
    syncDuration(reset: false)
    render()
    return getStatus()
  }

  func stop() -> [String: Any] {
    snapshot = [:]
    lastReason = nil
    startGeneration += 1
    stopPictureInPicture(byUser: false)
    return getStatus()
  }

  func seekVideo(positionMs: Double) -> [String: Any] {
    if let player, positionMs.isFinite {
      player.seek(to: CMTime(seconds: max(0, positionMs) / 1000, preferredTimescale: 600))
    }
    return getStatus()
  }

  private static func sanitized(_ dictionary: [String: Any]) -> [String: Any] {
    dictionary.filter { !($0.value is NSNull) }
  }

  // Nested dictionaries (`video`, `appearance`) are merged one level deep, so a partial
  // update such as `video: { paused: true }` keeps the other keys.
  private func merge(_ incoming: [String: Any]) {
    for (key, value) in incoming {
      if value is NSNull {
        snapshot.removeValue(forKey: key)
      } else if let new = value as? [String: Any], let old = snapshot[key] as? [String: Any] {
        snapshot[key] = old.merging(Self.sanitized(new)) { _, new in new }
      } else {
        snapshot[key] = value
      }
    }
  }

  private func emit(_ type: String, _ extra: [String: Any] = [:]) {
    var body = extra
    body["type"] = type
    body["status"] = getStatus()
    switch UIApplication.shared.applicationState {
    case .active: body["appState"] = "active"
    case .inactive: body["appState"] = "inactive"
    case .background: body["appState"] = "background"
    @unknown default: break
    }
    onEvent?(body)
  }

  private func fail(_ message: String) {
    active = false
    starting = false
    sessionLive = false
    durationRunning = false
    stopDurationTimer()
    releaseVideo()
    lastReason = message
    emit("error", ["message": message])
  }

  private func startPictureInPicture() {
    do {
      try configureAudioSession()
    } catch {
      lastReason = "Failed to activate audio session: \(error.localizedDescription)"
    }

    guard let sourceView = ensureSourceView() else {
      fail("Unable to attach PiP source view")
      return
    }

    let captionViewController = self.captionViewController ?? PipCaptionsViewController()
    self.captionViewController = captionViewController
    applyVideo()
    applySourceLayout()
    render()

    if pictureInPictureController == nil {
      let source = AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: sourceView,
        contentViewController: captionViewController
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      controller.requiresLinearPlayback = true
      pictureInPictureController = controller
    }

    guard let controller = pictureInPictureController else {
      fail("Unable to create Picture in Picture controller")
      return
    }

    startPictureInPictureWhenPossible(controller, retriesRemaining: 8, generation: startGeneration)
  }

  private func startPictureInPictureWhenPossible(
    _ controller: AVPictureInPictureController,
    retriesRemaining: Int,
    generation: Int
  ) {
    guard generation == startGeneration else {
      return
    }

    if controller.isPictureInPictureActive {
      active = true
      starting = false
      return
    }

    if controller.isPictureInPicturePossible {
      starting = true
      lastReason = nil
      controller.startPictureInPicture()
      return
    }

    guard retriesRemaining > 0 else {
      fail("Picture in Picture is not currently possible")
      return
    }

    starting = true
    lastReason = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.startPictureInPictureWhenPossible(
        controller,
        retriesRemaining: retriesRemaining - 1,
        generation: generation
      )
    }
  }

  private func stopPictureInPicture(byUser: Bool) {
    starting = false
    if let controller = pictureInPictureController, controller.isPictureInPictureActive {
      stopRequestedByApp = !byUser
      controller.stopPictureInPicture()
    } else {
      let wasActive = active
      active = false
      cleanupInlineSource()
      if wasActive {
        emit("stop", ["userInitiated": byUser])
      }
    }
  }

  private func configureAudioSession() throws {
    let mode = snapshot.string("iosAudioSession") ?? "playAndRecord"
    guard mode != "none" else {
      return
    }

    let session = AVAudioSession.sharedInstance()
    if session.category == .ambient || session.category == .soloAmbient {
      if mode == "playback" {
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
      } else {
        // `.allowBluetooth` was renamed to `.allowBluetoothHFP` in the iOS 26 SDK; the raw
        // value compiles cleanly against both old and new SDKs.
        let allowBluetoothHFP = AVAudioSession.CategoryOptions(rawValue: 0x4)
        try session.setCategory(
          .playAndRecord,
          mode: .spokenAudio,
          options: [.mixWithOthers, .defaultToSpeaker, allowBluetoothHFP, .allowBluetoothA2DP]
        )
      }
    }
    try session.setActive(true)
  }

  private func ensureSourceView() -> UIView? {
    if let sourceView, sourceView.window != nil {
      applySourceLayout()
      return sourceView
    }

    guard let rootView = UIApplication.shared.pipCaptionsRootView else {
      return nil
    }

    self.sourceView?.removeFromSuperview()
    let sourceView = UIView()
    sourceView.translatesAutoresizingMaskIntoConstraints = false
    sourceView.backgroundColor = .clear
    sourceView.isUserInteractionEnabled = false
    sourceView.alpha = 0.02
    rootView.addSubview(sourceView)

    let widthConstraint = sourceView.widthAnchor.constraint(equalToConstant: 430)
    let heightConstraint = sourceView.heightAnchor.constraint(equalToConstant: 236)
    NSLayoutConstraint.activate([
      sourceView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      widthConstraint,
      heightConstraint,
      sourceView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
    ])

    self.sourceView = sourceView
    sourceWidthConstraint = widthConstraint
    sourceHeightConstraint = heightConstraint
    applySourceLayout()
    return sourceView
  }

  private func applySourceLayout() {
    guard let sourceView, let rootView = sourceView.superview else {
      return
    }

    rootView.layoutIfNeeded()
    let containerWidth = rootView.bounds.width > 0 ? rootView.bounds.width : UIScreen.main.bounds.width
    let metrics = PipCaptionsLayoutMetrics.resolve(
      snapshot: snapshot,
      containerWidth: containerWidth,
      videoAspect: videoAspect
    )
    sourceWidthConstraint?.constant = metrics.sourceWidth
    sourceHeightConstraint?.constant = metrics.sourceHeight
    rootView.layoutIfNeeded()
  }

  private func cleanupInlineSource() {
    stopDurationTimer()
    sessionLive = false
    durationRunning = false
    releaseVideo()
    sourceView?.removeFromSuperview()
    sourceView = nil
    pictureInPictureController = nil
    captionViewController = nil
  }

  private func render() {
    captionViewController?.render(
      snapshot: snapshot,
      durationText: durationText(),
      player: player,
      videoAspect: videoAspect
    )
  }

  // MARK: - Video

  private func applyVideo() {
    let video = snapshot.dictionary("video")
    guard sessionLive, let uri = video.string("uri"), let url = Self.videoURL(from: uri) else {
      releaseVideo()
      return
    }

    if uri != loadedVideoURI {
      releaseVideo()
      loadVideo(uri: uri, url: url, options: video)
    }

    guard let player else {
      return
    }
    player.isMuted = video.bool("muted", default: false)
    player.volume = Float(min(max(video.double("volume") ?? 1, 0), 1))
    if video.bool("paused", default: false) {
      player.pause()
    } else {
      player.play()
    }
  }

  private func loadVideo(uri: String, url: URL, options: [String: Any]) {
    var assetOptions: [String: Any] = [:]
    if let headers = options["headers"] as? [String: String], !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }

    let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions))
    let player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .pause
    if let startMs = options.double("positionMs"), startMs > 0 {
      player.seek(to: CMTime(seconds: startMs / 1000, preferredTimescale: 600))
    }

    videoObservations = [
      item.observe(\.status, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async {
          self?.videoStatusChanged(item)
        }
      },
      item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
        DispatchQueue.main.async {
          self?.videoSizeChanged(item)
        }
      }
    ]
    videoEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.videoDidEnd()
    }

    self.player = player
    loadedVideoURI = uri
    // Assumed until the real size is known.
    videoAspect = 16.0 / 9.0
  }

  private func releaseVideo() {
    videoObservations.forEach { $0.invalidate() }
    videoObservations = []
    if let videoEndObserver {
      NotificationCenter.default.removeObserver(videoEndObserver)
    }
    videoEndObserver = nil
    player?.pause()
    player = nil
    loadedVideoURI = nil
    videoAspect = nil
  }

  private func videoStatusChanged(_ item: AVPlayerItem) {
    guard item === player?.currentItem else {
      return
    }
    switch item.status {
    case .readyToPlay:
      emit("videoReady")
    case .failed:
      emit("videoError", ["message": item.error?.localizedDescription ?? "Unable to play the video"])
    default:
      break
    }
  }

  private func videoSizeChanged(_ item: AVPlayerItem) {
    let size = item.presentationSize
    guard item === player?.currentItem, size.width > 0, size.height > 0 else {
      return
    }
    videoAspect = size.width / size.height
    applySourceLayout()
    render()
  }

  private func videoDidEnd() {
    guard let player else {
      return
    }
    if snapshot.dictionary("video").bool("loop", default: false) {
      player.seek(to: .zero)
      player.play()
    } else {
      emit("videoEnd")
    }
  }

  private static func videoURL(from uri: String) -> URL? {
    if uri.hasPrefix("/") {
      return URL(fileURLWithPath: uri)
    }
    return URL(string: uri)
  }

  // MARK: - Duration

  private var usesStaticDurationLabel: Bool {
    snapshot.double("durationMs") == nil && snapshot.string("durationLabel") != nil
  }

  private func syncDuration(reset: Bool) {
    let now = CACurrentMediaTime()
    let incoming = max(0, snapshot.double("durationMs") ?? 0)
    // JS may be suspended in the background and resume with a stale value, so the
    // native clock only ever moves forward within one session.
    durationBaseMs = reset ? incoming : max(currentDurationMs(now: now), incoming)
    durationAnchor = now
    durationRunning = sessionLive && !snapshot.bool("isPaused", default: false)

    if durationRunning && !usesStaticDurationLabel && snapshot.bool("showDuration", default: true) {
      startDurationTimer()
    } else {
      stopDurationTimer()
    }
  }

  private func currentDurationMs(now: CFTimeInterval = CACurrentMediaTime()) -> Double {
    durationBaseMs + (durationRunning ? max(0, now - durationAnchor) * 1000 : 0)
  }

  private func durationText() -> String {
    if usesStaticDurationLabel, let label = snapshot.string("durationLabel") {
      return label
    }

    let totalSeconds = Int(currentDurationMs() / 1000)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }

  private func startDurationTimer() {
    guard durationTimer == nil else {
      return
    }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.captionViewController?.setDurationText(self.durationText())
    }
    RunLoop.main.add(timer, forMode: .common)
    durationTimer = timer
  }

  private func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    starting = true
    lastReason = nil
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    active = true
    starting = false
    lastReason = nil
    emit("start")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    cleanupInlineSource()
    fail(error.localizedDescription)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    let byUser = !stopRequestedByApp
    stopRequestedByApp = false
    active = false
    starting = false
    cleanupInlineSource()
    emit("stop", ["userInitiated": byUser])
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      self?.stopPictureInPicture(byUser: true)
      completionHandler(false)
    }
  }
}

private final class PipCaptionsViewController: AVPictureInPictureVideoCallViewController {
  private static let defaultBackgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
  private static let defaultDurationColor = UIColor(white: 1, alpha: 0.62)

  private let headerRow = UIStackView()
  private let iconView = UIImageView()
  private let durationLabel = UILabel()
  private let transcriptScrollView = UIScrollView()
  private let transcriptLabel = UILabel()
  private let stackView = UIStackView()
  private var iconWidthConstraint: NSLayoutConstraint?
  private var iconHeightConstraint: NSLayoutConstraint?
  private var stackLeadingConstraint: NSLayoutConstraint?
  private var stackTrailingConstraint: NSLayoutConstraint?
  private var stackTopConstraint: NSLayoutConstraint?
  private var stackBottomConstraint: NSLayoutConstraint?
  private var stackBottomPinnedConstraint: NSLayoutConstraint?
  private var transcriptHeightConstraint: NSLayoutConstraint?
  private var loadedIconName: String??
  private var playerLayer: AVPlayerLayer?
  private let captionScrim = UIView()
  private var videoMode = false
  private var videoCaptionMaxHeight: CGFloat = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Self.defaultBackgroundColor
    view.layer.masksToBounds = true

    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.spacing = 10
    stackView.translatesAutoresizingMaskIntoConstraints = false

    // Keeps captions readable on top of bright video frames.
    captionScrim.translatesAutoresizingMaskIntoConstraints = false
    captionScrim.backgroundColor = UIColor(white: 0, alpha: 0.5)
    captionScrim.isHidden = true
    view.addSubview(captionScrim)
    view.addSubview(stackView)

    headerRow.axis = .horizontal
    headerRow.alignment = .center

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.clipsToBounds = true

    durationLabel.font = .systemFont(ofSize: 13, weight: .medium)
    durationLabel.textColor = Self.defaultDurationColor
    durationLabel.textAlignment = .right
    durationLabel.numberOfLines = 1
    durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
    transcriptScrollView.alwaysBounceVertical = false
    transcriptScrollView.showsVerticalScrollIndicator = false
    transcriptScrollView.showsHorizontalScrollIndicator = false
    transcriptScrollView.backgroundColor = .clear

    transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
    transcriptLabel.font = .systemFont(ofSize: 19, weight: .regular)
    transcriptLabel.textColor = .white
    transcriptLabel.numberOfLines = 0
    transcriptLabel.lineBreakMode = .byWordWrapping
    transcriptLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    transcriptLabel.setContentHuggingPriority(.required, for: .vertical)

    headerRow.addArrangedSubview(iconView)
    headerRow.addArrangedSubview(UIView())
    headerRow.addArrangedSubview(durationLabel)

    stackView.addArrangedSubview(headerRow)
    stackView.addArrangedSubview(transcriptScrollView)
    transcriptScrollView.addSubview(transcriptLabel)

    let metrics = PipCaptionsLayoutMetrics.resolve(snapshot: [:], containerWidth: 430)
    preferredContentSize = metrics.preferredSize
    view.layer.cornerRadius = metrics.cornerRadius

    let iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: metrics.iconSize)
    let iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: metrics.iconSize)
    let stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: metrics.horizontalInset)
    let stackTrailingConstraint = stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -metrics.horizontalInset)
    let stackTopConstraint = stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: metrics.topInset)
    let stackBottomConstraint = stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -metrics.bottomInset)
    let transcriptHeightConstraint = transcriptScrollView.heightAnchor.constraint(equalToConstant: Self.transcriptViewportHeight(for: metrics))
    self.iconWidthConstraint = iconWidthConstraint
    self.iconHeightConstraint = iconHeightConstraint
    self.stackLeadingConstraint = stackLeadingConstraint
    self.stackTrailingConstraint = stackTrailingConstraint
    self.stackTopConstraint = stackTopConstraint
    self.stackBottomConstraint = stackBottomConstraint
    self.transcriptHeightConstraint = transcriptHeightConstraint
    stackBottomPinnedConstraint = stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -metrics.bottomInset)

    NSLayoutConstraint.activate([
      iconWidthConstraint,
      iconHeightConstraint,
      stackLeadingConstraint,
      stackTrailingConstraint,
      stackTopConstraint,
      stackBottomConstraint,
      transcriptHeightConstraint,
      captionScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      captionScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      captionScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      captionScrim.topAnchor.constraint(equalTo: stackView.topAnchor, constant: -8),
      transcriptLabel.leadingAnchor.constraint(equalTo: transcriptScrollView.contentLayoutGuide.leadingAnchor),
      transcriptLabel.trailingAnchor.constraint(equalTo: transcriptScrollView.contentLayoutGuide.trailingAnchor),
      transcriptLabel.topAnchor.constraint(equalTo: transcriptScrollView.contentLayoutGuide.topAnchor),
      transcriptLabel.bottomAnchor.constraint(equalTo: transcriptScrollView.contentLayoutGuide.bottomAnchor),
      transcriptLabel.widthAnchor.constraint(equalTo: transcriptScrollView.frameLayoutGuide.widthAnchor)
    ])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer?.frame = view.bounds
    CATransaction.commit()
    updateCaptionMaxLayoutWidth()
    if videoMode {
      updateVideoCaptionHeight()
    }
  }

  func render(snapshot: [String: Any], durationText: String, player: AVPlayer?, videoAspect: CGFloat?) {
    loadViewIfNeeded()
    videoMode = player != nil
    applyPlayer(player, cover: snapshot.dictionary("video").string("resizeMode") == "cover")

    applyHeader(snapshot: snapshot)
    applyLayout(snapshot: snapshot, videoAspect: videoAspect)

    durationLabel.text = durationText

    let lines = Self.captionLines(from: snapshot)
    // Over a video the placeholder only shows when the app asked for one.
    let placeholder = snapshot.string("placeholder") ?? (videoMode ? nil : "Listening...")
    let text = lines.isEmpty ? placeholder : lines.joined(separator: "\n")
    transcriptLabel.text = text
    transcriptScrollView.isHidden = text == nil
    captionScrim.isHidden = !videoMode || text == nil
    if videoMode {
      updateVideoCaptionHeight()
    }
    scrollTranscriptToBottom()
  }

  // The player layer only exists while there is a video, so a captions-only window
  // carries no video machinery at all.
  private func applyPlayer(_ player: AVPlayer?, cover: Bool) {
    guard let player else {
      playerLayer?.removeFromSuperlayer()
      playerLayer = nil
      return
    }

    let layer = playerLayer ?? AVPlayerLayer()
    if playerLayer == nil {
      layer.frame = view.bounds
      view.layer.insertSublayer(layer, at: 0)
      playerLayer = layer
    }
    if layer.player !== player {
      layer.player = player
    }
    layer.videoGravity = cover ? .resizeAspectFill : .resizeAspect
  }

  func setDurationText(_ text: String) {
    durationLabel.text = text
  }

  private func applyHeader(snapshot: [String: Any]) {
    let iconName = snapshot.string("iconName")
    if loadedIconName != .some(iconName) {
      loadedIconName = .some(iconName)
      iconView.image = Self.loadIcon(named: iconName)
    }

    iconView.isHidden = !snapshot.bool("showIcon", default: true) || iconView.image == nil
    durationLabel.isHidden = !snapshot.bool("showDuration", default: true)
    // The header is not drawn over a video; captions sit at the bottom edge instead.
    headerRow.isHidden = videoMode || (iconView.isHidden && durationLabel.isHidden)
  }

  private func applyLayout(snapshot: [String: Any], videoAspect: CGFloat?) {
    let containerWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
    let metrics = PipCaptionsLayoutMetrics.resolve(
      snapshot: snapshot,
      containerWidth: containerWidth,
      videoAspect: videoAspect
    )
    let appearance = snapshot.dictionary("appearance")

    preferredContentSize = metrics.preferredSize
    view.backgroundColor = videoMode
      ? .black
      : (appearance.color("backgroundColor") ?? Self.defaultBackgroundColor)
    view.layer.cornerRadius = metrics.cornerRadius
    headerRow.spacing = metrics.headerSpacing
    iconView.layer.cornerRadius = metrics.iconSize * 0.22
    iconWidthConstraint?.constant = metrics.iconSize
    iconHeightConstraint?.constant = metrics.iconSize
    stackLeadingConstraint?.constant = metrics.horizontalInset
    stackTrailingConstraint?.constant = -metrics.horizontalInset
    stackTopConstraint?.constant = metrics.topInset
    stackBottomConstraint?.constant = -metrics.bottomInset
    stackBottomPinnedConstraint?.constant = -metrics.bottomInset
    if videoMode {
      NSLayoutConstraint.deactivate([stackTopConstraint, stackBottomConstraint].compactMap { $0 })
      stackBottomPinnedConstraint?.isActive = true
      let visibleLines: CGFloat = snapshot.string("variant") == "mini" ? 2 : 3
      videoCaptionMaxHeight = ceil(metrics.captionFontSize * 1.25 * visibleLines)
    } else {
      stackBottomPinnedConstraint?.isActive = false
      NSLayoutConstraint.activate([stackTopConstraint, stackBottomConstraint].compactMap { $0 })
      transcriptHeightConstraint?.constant = Self.transcriptViewportHeight(
        for: metrics,
        headerHidden: headerRow.isHidden
      )
    }
    durationLabel.font = .systemFont(ofSize: max(12, metrics.statusFontSize - 1), weight: .medium)
    durationLabel.textColor = appearance.color("durationColor") ?? Self.defaultDurationColor
    transcriptLabel.font = .systemFont(ofSize: metrics.captionFontSize, weight: .regular)
    transcriptLabel.textColor = appearance.color("textColor") ?? .white
    updateCaptionMaxLayoutWidth()
    view.setNeedsLayout()
  }

  private func updateCaptionMaxLayoutWidth() {
    let leading = stackLeadingConstraint?.constant ?? 0
    let trailing = abs(stackTrailingConstraint?.constant ?? 0)
    let width = view.bounds.width - leading - trailing
    if width > 0 {
      transcriptLabel.preferredMaxLayoutWidth = width
    }
  }

  // Over a video the caption area hugs its text, up to a few lines, so it covers as
  // little of the picture as possible.
  private func updateVideoCaptionHeight() {
    let inset = stackLeadingConstraint?.constant ?? 0
    let viewWidth = view.bounds.width > 0 ? view.bounds.width : preferredContentSize.width
    let availableWidth = viewWidth - inset * 2
    guard availableWidth > 0 else {
      return
    }
    let textHeight = transcriptLabel.sizeThatFits(
      CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
    ).height
    let height = min(ceil(textHeight), videoCaptionMaxHeight)
    if transcriptHeightConstraint?.constant != height {
      transcriptHeightConstraint?.constant = height
    }
  }

  // Keeps the newest caption visible once the text outgrows the viewport.
  private func scrollTranscriptToBottom() {
    view.layoutIfNeeded()
    transcriptScrollView.layoutIfNeeded()
    transcriptScrollView.setContentOffset(CGPoint(x: 0, y: maxTranscriptOffsetY), animated: false)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.transcriptScrollView.setContentOffset(CGPoint(x: 0, y: self.maxTranscriptOffsetY), animated: false)
    }
  }

  private var maxTranscriptOffsetY: CGFloat {
    max(
      0,
      transcriptScrollView.contentSize.height - transcriptScrollView.bounds.height + transcriptScrollView.adjustedContentInset.bottom
    )
  }

  private static func transcriptViewportHeight(
    for metrics: PipCaptionsLayoutMetrics,
    headerHidden: Bool = false
  ) -> CGFloat {
    let headerHeight = headerHidden ? 0 : metrics.iconSize + metrics.headerSpacing
    return max(
      metrics.captionFontSize * CGFloat(metrics.captionScrollMaxLines) * 1.25,
      metrics.sourceHeight - metrics.topInset - metrics.bottomInset - headerHeight
    )
  }

  private static func captionLines(from snapshot: [String: Any]) -> [String] {
    let items = snapshot["items"] as? [[String: Any]] ?? []
    let maxItems = max(1, snapshot.int("maxVisibleItems") ?? 5)
    let mode = snapshot.string("captionMode") ?? "auto"

    return items.suffix(maxItems).compactMap { item in
      let text = item.string("text")
      let translated = item.string("translatedText")
      let fallback = item.string("displayText")

      switch mode {
      case "original":
        return text ?? translated ?? fallback
      case "bilingual":
        let lines = [text, translated == text ? nil : translated].compactMap { $0 }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
      default:
        return translated ?? text ?? fallback
      }
    }
  }

  private static func loadIcon(named name: String?) -> UIImage? {
    if let name, let image = UIImage(named: name) {
      return image
    }

    if let image = UIImage(named: "AppIcon") {
      return image
    }

    guard
      let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
      let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
      let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
      let iconName = iconFiles.last
    else {
      return nil
    }

    return UIImage(named: iconName)
  }
}

private extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? {
    guard let value = self[key] as? String else {
      return nil
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
  }

  func bool(_ key: String, default defaultValue: Bool) -> Bool {
    self[key] as? Bool ?? defaultValue
  }

  func double(_ key: String) -> Double? {
    guard let value = (self[key] as? NSNumber)?.doubleValue, value.isFinite else {
      return nil
    }
    return value
  }

  func int(_ key: String) -> Int? {
    double(key).map { Int($0) }
  }

  func dictionary(_ key: String) -> [String: Any] {
    self[key] as? [String: Any] ?? [:]
  }

  /// Colors arrive as ARGB integers produced by React Native's `processColor`.
  func color(_ key: String) -> UIColor? {
    guard let value = self[key] as? NSNumber else {
      return nil
    }
    let argb = UInt32(truncatingIfNeeded: value.int64Value)
    return UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }
}

private extension Double {
  var finiteOrZero: Double {
    isFinite ? self : 0
  }
}

private extension UIApplication {
  var pipCaptionsRootView: UIView? {
    let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
    let foregroundScenes = scenes.filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

    for scene in foregroundScenes + scenes {
      if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow.rootViewController?.view ?? keyWindow
      }
      if let window = scene.windows.first(where: { !$0.isHidden }) {
        return window.rootViewController?.view ?? window
      }
    }

    return nil
  }
}
