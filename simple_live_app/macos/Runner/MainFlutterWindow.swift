import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // 禁用窗口大小自动保存/恢复，避免跨显示器时系统按屏幕记忆自动调整窗口大小
  override var frameAutosaveName: NSWindow.FrameAutosaveName {
    get { NSWindow.FrameAutosaveName("") }
  }

  override func saveFrame(usingName name: NSWindow.FrameAutosaveName) { }

  override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool { false }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
