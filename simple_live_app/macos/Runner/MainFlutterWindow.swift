import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(frameRect, display: flag)
    // 程序调用 setSize 时也保存 frame，与手动拖拽行为一致。
    // 否则跨显示器时系统会用旧的 frame 缓存，导致窗口大小跳变。
    if !frameAutosaveName.isEmpty {
      saveFrame(usingName: frameAutosaveName)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
