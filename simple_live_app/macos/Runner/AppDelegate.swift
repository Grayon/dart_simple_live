import Cocoa
import FlutterMacOS

@NSApplicationMain
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    // 退出应用时清除窗口 frame 缓存，避免小窗模式下退出导致下次启动窗口很小
    if let window = NSApp.mainWindow {
      let name = window.frameAutosaveName
      if !name.isEmpty {
        window.saveFrame(usingName: NSWindow.FrameAutosaveName(""))
      }
    }
    // 清除 UserDefaults 中保存的窗口 frame
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame MainFlutterWindow")
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame QvC-M9-y7g")
  }
}
