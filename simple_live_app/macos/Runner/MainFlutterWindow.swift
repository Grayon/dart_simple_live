import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // 禁用系统窗口自动恢复，避免 macOS 按显示器缓存窗口大小，
    // 导致小窗模式跨屏时窗口大小跳变。
    isRestorable = false
    frameAutosaveName = ""

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
