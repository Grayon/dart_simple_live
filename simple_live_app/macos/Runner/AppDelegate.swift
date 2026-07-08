import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
}
