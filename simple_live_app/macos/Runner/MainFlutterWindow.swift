import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 禁用窗口大小自动保存/恢复，避免跨显示器时系统按屏幕记忆自动调整窗口大小
    self.setFrameAutosaveName(NSWindow.FrameAutosaveName(""))

    super.awakeFromNib()
  }
}
