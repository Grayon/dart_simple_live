import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 与 Flutter 通信的通道，用于在应用退出前通知 Flutter 释放播放器等资源
  private var terminationChannel: FlutterMethodChannel?

  /// 标记是否已经通知过 Flutter 即将退出，避免重复请求
  private var isTerminationInProgress = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
      if key.hasPrefix("NSWindow Frame ") {
        defaults.removeObject(forKey: key)
      }
    }
  }

  /// 拦截应用退出：先通知 Flutter 释放 mpv 播放器，再允许退出。
  /// 否则 mpv core 线程仍在运行时主线程已 munmap 释放内存，导致 SIGSEGV。
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // 已经通知过 Flutter 并在等待回复时，直接放行
    if isTerminationInProgress {
      return .terminateNow
    }

    guard let controller = mainWindow?.flutterViewController else {
      return .terminateNow
    }

    let channel = FlutterMethodChannel(
      name: "com.xycz.simpleLiveApp/lifecycle",
      binaryMessenger: controller.engine.binaryMessenger
    )
    terminationChannel = channel
    isTerminationInProgress = true

    channel.invokeMethod("onApplicationWillTerminate", arguments: nil) { _ in
      // Flutter 处理完毕（播放器已释放），继续退出
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    return .terminateLater
  }

  private var mainWindow: MainFlutterWindow? {
    return NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first
  }
}
