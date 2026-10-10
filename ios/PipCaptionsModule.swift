import ExpoModulesCore
import Foundation

private let stateChangeEvent = "onStateChange"

public class PipCaptionsModule: Module {
  private let controller = PipCaptionsController()

  public func definition() -> ModuleDefinition {
    Name("ExpoPipCaptions")

    Events(stateChangeEvent)

    OnCreate {
      self.controller.onEvent = { [weak self] body in
        self?.sendEvent(stateChangeEvent, body)
      }
    }

    OnDestroy {
      let controller = self.controller
      DispatchQueue.main.async {
        _ = controller.stop()
      }
    }

    // The controller drives UIKit and AVKit, so every function runs on the main queue.
    AsyncFunction("getStatusAsync") { () -> [String: Any] in
      return self.controller.getStatus()
    }.runOnQueue(.main)

    AsyncFunction("requestPermissionAsync") { () -> [String: Any] in
      return self.controller.requestPermission()
    }.runOnQueue(.main)

    AsyncFunction("startAsync") { (options: [String: Any]) -> [String: Any] in
      return self.controller.start(options: options)
    }.runOnQueue(.main)

    AsyncFunction("updateAsync") { (snapshot: [String: Any]) -> [String: Any] in
      return self.controller.update(snapshot: snapshot)
    }.runOnQueue(.main)

    AsyncFunction("pauseAsync") { (paused: Bool) -> [String: Any] in
      return self.controller.pause(paused: paused)
    }.runOnQueue(.main)

    AsyncFunction("seekVideoAsync") { (positionMs: Double) -> [String: Any] in
      return self.controller.seekVideo(positionMs: positionMs)
    }.runOnQueue(.main)

    AsyncFunction("sendDanmakuAsync") { (items: [[String: Any]]) -> [String: Any] in
      return self.controller.sendDanmaku(items: items)
    }.runOnQueue(.main)

    AsyncFunction("stopAsync") { () -> [String: Any] in
      return self.controller.stop()
    }.runOnQueue(.main)
  }
}
