import Cocoa
import FlutterMacOS

@NSApplicationMain
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // 禁用窗口恢复后，清除可能残留的 frame 缓存。
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys {
      if key.hasPrefix("NSWindow Frame ") {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
