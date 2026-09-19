import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 暴露给 AppDelegate，用于在应用退出前通过 MethodChannel 通知 Flutter 释放资源
  private(set) var flutterViewController: FlutterViewController?

  override func awakeFromNib() {
    // 禁用系统窗口自动恢复，避免 macOS 按显示器缓存窗口大小，
    // 导致小窗模式跨屏时窗口大小跳变。
    isRestorable = false
    setFrameAutosaveName("")

    let controller = FlutterViewController()
    flutterViewController = controller
    let windowFrame = self.frame
    self.contentViewController = controller
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: controller)

    super.awakeFromNib()
  }
}
